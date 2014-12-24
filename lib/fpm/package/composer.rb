#
# encoding: utf-8
# api: fpm
# title: Composer source
# description: Converts composer bundles into system or/and phar packages
# type: package
# depends: bin:composer
# category: source
# version: 0.3
# state: beta
# license: MITL
# author: mario#include-once:org
# 
# Creates system packages for composer/packagist bundles.
#
#  → Either works on individual vendor/*/*/ paths as input
#    (the vendor/ prefix can be omitted).
#
#  → Or downloads a single vnd/pkgname bundle.
#
# Also supports different target variations:
#
#  → Syspackages (deb/rpm) end up in /usr/share/php/vendor/vnd/pkg/.
#    The composer.json is augmented with lock[] data to permit
#    rebuilding composer.lock and file-autoloading.
#
#  → Whereas --composer-phar creates Phars matroskaed into system
#    packages, with target names of /usr/share/php/vnd-pkg.phar.
#
#  → With a standard `-t phar` target it'll just compact individual
#    components into localized phars.
#
# NOTES
#
# → The vendor/ prefix is retained and enforced to prevent clashes
#   with PEAR and system packages.
# → Invokes `composer require`, merges composer.lock information into
#   per-bundle vnd/name/composer.json→extra→lock.
# → System packagess require a manual composer.json assembly/update,
#   as composer can't reconstruct them or its .lock from dirs.
# ø Unclear: require/use `-u composer` for reading meta?
# * Bring in line with Debian packaging scheme, dh_phpcomposer/pkg-php
#   drop -composer- in package names, get rid of /vendor/deep/dirs/
#   and adopt complete version/dependency translation after all?
# ø Dependencies are not in line with RPM recommendations,
#   http://fedoraproject.org/wiki/Packaging:PHP
#   https://twiki.cern.ch/twiki/bin/view/Main/RPMAndDebVersioning
#

require "fpm/package"
require "fpm/util"
require "fpm/errors"
require "fpm/package/zip"
require "fileutils"
require "json"


# Composer reading (source only)
class FPM::Package::Composer < FPM::Package

  option "--ver", "1.0\@dev", "Which version to checkout", :default=>nil
  option "--phar", :flag, "Convert bundle into .phar plugin package", :default=>false
  
  attr_accessor :as_phar      # detect -t phar and --composer-phar flags
  attr_accessor :once         # prevent double .input() invocation
  attr_accessor :name_prefix  # hold "php-composer" or "php-phar" prefix

  def initialize(*args)
    super(*args)
    @architecture = "all"
    @name_prefix = "php-composer"
    @as_phar = false
    @once = false
    @attrs[:composer] = {}
  end

  # download composer bundle, or compact from existing vendor/ checkout
  def input(in_bundle)

    # general params
    as_phar = attributes[:composer_phar_given?] || attributes[:output_type].match(/phar/)
    in_bundle = in_bundle.gsub(/^(.+\/+)*vendor\/+|\/(?=\/)|\/+$/, "")
    @name = in_bundle.gsub(/[\W]+/, "-")
    lock = {}
    target_dir = ""
    if once
      once = true
      raise FPM::InvalidPackageConfiguration, "You can't input multiple bundle names. "\
          "Only one package can be built at a time currently. Use a shell loop please."
    end
    if in_bundle =~ /^composer\/\w+\.\w+/
      logger.warn("composer/*.* files specified as input")
      return
    end

    # copying or download mode
    if File.exist?("vendor/" + in_bundle)
      # prepare a single vendor/*/* input directory
      FileUtils.cp("composer.lock", build_path)
      FileUtils.mkdir_p(dest = "#{build_path}/vendor/#{in_bundle}")
      FileUtils.cp_r(::Dir.glob("./vendor/#{in_bundle}/*"), dest)
    else
      # download one package (and dependencies, which are thrown away afterwards)
      ::Dir.chdir(build_path) do
        ver = attributes[:composer_ver]
        safesystem(
          composer, "require", "--prefer-dist", "--update-no-dev", "--ignore-platform-reqs",
          "--no-ansi", "--no-interaction", in_bundle, *(ver ? [ver] : [])
        )
        FileUtils.rm_r(["vendor/composer", "vendor/autoload.php"])
      end
    end

    # extract composer lock{} list, update fpm meta fields, and merge into pkgs` composer.json
    ::Dir.chdir(build_path) do
      lock = parse_lock("composer.lock")
      if lock.key? in_bundle
        target_dir = lock[in_bundle]["target-dir"]
      else
        raise FPM::InvalidPackageConfiguration, "Package name #{in_bundle} absent in composer.lock"
      end
      inject_lock("vendor/#{in_bundle}/#{target_dir}/composer.json", lock[in_bundle])
      composer_json_import(lock[in_bundle])
    end

    #-- staging
    # eventually move this to convert() or converted_from()..
    
    # system package (deb/rpm) with raw files under /usr/share/php/vendor/
    if !as_phar
      name = "php-composer-#{name}"
      attributes[:prefix] ||= "/usr/share/php/vendor/#{in_bundle}"
      FileUtils.mkdir_p("#{staging_path}/usr/share/php")
      FileUtils.mv("#{build_path}/vendor", "#{staging_path}/usr/share/php")

    # phar packages, lose deep nesting
    else
      build_deep = "#{build_path}/vendor/#{in_bundle}/#{target_dir}"
      attributes[:phar_format] = "zip+gz" unless attributes[:phar_format_given?]

      # becomes local -t phar
      if !attributes[:composer_phar_given?]
        FileUtils.mv(::Dir.glob("#{build_deep}/*"), staging_path)

      # matroska phar-in-deb/rpm, ends up in /usr/share/php/*.phar
      else
        #(should warn about combination with -t phar)
        FileUtils.mkdir_p(staging_dest = "#{staging_path}/usr/share/php")
        ::Dir.chdir("#{build_deep}") do
          phar = convert(FPM::Package::Phar)
          phar.instance_variable_set(:@staging_path, ".")
          phar.output("#{staging_dest}/#{name}.phar");
          phar.cleanup_build
        end
        @name = "php-phar-#{name}"
      end
    end
    cleanup_build
  end # def output


  # collect per-package composer.json infos
  def composer_json_import(json)
    if json.key? "name" and not attributes[:vendor_given?]
      @vendor = json["name"].split(/\W/).first
    end
    if json.key? "version" and not attributes[:version_given?]
      @version = json["version"].sub(/^v/, "")
    end
    if json.key? "description" and not attributes[:description_given?]
      @description = json["description"]
    end
    if json.key? "license" and not attributes[:license_given?]
      @license = [json["license"]].flatten.join(", ")
    end
    if json.key? "homepage" and not attributes[:url_given?]
      @url = json["homepage"]
    end
    if json.key? "authors" and not attributes[:maintainer_given?]
      @maintainer = json["authors"].map{ |v| v.values.join(", ") }.first or nil
    end
    if json.key? "require" and dependencies.empty?
      @dependencies += json["require"].collect { |k,v| require_convert(k,v) }.flatten
    end
    # stash away complete composer struct for possible phar building
    @attrs[:composer] = json
  end

  # translate package names and versions
  def require_convert(k, v)

    # package names, magic values
    k = k.strip.gsub(/\W+/, "-")
    if @as_phar
      if k =~ /^php|^hhvm|^quercus/
        k = "php"
      elsif k =~ /^ext-(\w+)$/
        k = "php:#{$1}"
      elsif k =~ /^lib-(\w+)$/
        k = "sys:lib#{$1}"
      elsif k =~ /^bin-(\w+)$/
        k = "bin:#{$1}"
      else
        k
      end
    else
      if k =~ /^php|^hhvm|^quercus/
        k = "php5-common"
      elsif k =~ /^ext-(\w+)$/
        k = "php5-#{$1}"
      elsif k =~ /^lib-(\w+)$/
        k = "lib#{$1}"
      else
        k = "php-composer-#{k}"
      end
    end

    # expand version specifiers (this is intentionally incomplete)
    if attributes[:no_depends_given?]
      v = ""
    else
      v = v.split(",").map {
        |v|
        case v.gsub(/\s+|^v/, "").to_s
          when "*"
            ""
          when /^(.+)\.\*/  # 1.0.*
            " >= #{$1}.0"
          when /^[\d.-]+$/  # 1.0.1
            " = #{v}"
          when /^([><=]*)([\d.-]+)$/  # >= 2.0   # debianize_op() normalizes >, <, = anyway
            " #{$1} #{$2}"
          when /^~\s*([\d.-]+)$/  # ~2.0   # deb.fix_dependency translates that into a range ["pkg(>=1)", "pkg(<<2)"]
            " ~> #{$1}"
          else
            ""
        end
      }
    end
    return k ? v.map { |v| k + v } : nil
  end


  # Extract package sections from composer.lock file, turn into pkgname→hash
  def parse_lock(fn)
    json = JSON.parse(File.read(fn))
    FileUtils.rm(fn)  # not needed afterwards (this is run within the build_path)
    if !json.key? "packages"
      json["packages"] = []
    end
    if json.key? "packages-dev"
      json["packages"] += json["packages-dev"]
    end
    Hash[  json["packages"].map{ |entry| [entry["name"], entry] }  ]
  end
  
  # Add composer.lock package date into per-package composer.json→extra→lock
  def inject_lock(fn, extra)
    json = JSON.parse(File.read(fn))
    json["extra"] ||= {}
    json["extra"]["lock"] = extra
    File.write(fn, JSON.pretty_generate(json))
  end

  # Locate composer binary
  def composer
    (`which composer` or `which composer.phar` or ("php "+`locate composer.phar`)).split("\n").first
  end

end # class ::Composer
