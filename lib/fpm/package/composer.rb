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
#  → Syspackages (deb/rpm) end up in /usr/share/php/Vnd/Pkg.
#
#  → Whereas --composer-phar creates Phars embedded into system
#    packages, with target names of /usr/share/php/vnd-pkg.phar.
#
#  → With a standard `-t phar` target it'll just compact individual
#    components into localized phars.
#
# NOTES
#
# → Currently rewritten to conform to Debian pkg-php-tools and Fedora
#   schemes.
# → The vendor/ prefix isn't retained any longer. Composer wasn't meant
#   to manage globally installed libraries.
# → System packages thus need a global autoloader (shared.phar / phpab)
#   or manual includes.
# → The build process utilizes `composer require` to fetch new packages,
#   if xpm -s composer isn't run from within a composer managed project.
# * Bring in line with Debian packaging scheme, dh_phpcomposer/pkg-php
#   drop -composer- in package names, get rid of /vendor/deep/dirs/
#   and adopt complete version/dependency translation after all?
# ø Dependencies are not in line with RPM recommendations,
#   http://fedoraproject.org/wiki/Packaging:PHP
#   https://twiki.cern.ch/twiki/bin/view/Main/RPMAndDebVersioning
# ø Unclear: require/use `-u composer` for reading meta?
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
  
  public
  attr_accessor :in_bundle

  def initialize(*args)
    super(*args)
    @architecture = "all"
    @name_prefix = ""      # hold "php-" or "phar-" syspackage name prefix
    @target_dir = nil      # two-level base directory under /usr/share/php
    @in_bundle = "n/a"     # packagist bundle name
    @as_phar = false       # detect -t phar and --composer-phar flags
    @once = false          # prevent double .input() invocation
    @attrs[:composer] = {}
  end

  # download composer bundle, or compact from existing vendor/ checkout
  def input(vnd_pkg_path)

    # general params
    @as_phar = attributes[:composer_phar_given?] || attributes[:output_type].match(/phar/)
    in_bundle = vnd_pkg_path.gsub(/^(.+\/+)*vendor\/+|\/(?=\/)|\/+$/, "")
    @name = in_bundle.gsub(/[\W]+/, "-")
    lock = {}
    if @once
      @once = true
      raise FPM::InvalidPackageConfiguration, "You can't input multiple bundle names. "\
          "Only one package can be built at a time currently. Use a shell loop please."
    end
    if in_bundle =~ /^composer\/\w+\.\w+/
      logger.warn("composer/*.* files specified as input")
      return
    end

    # copying mode
    if File.exist?("vendor/" + in_bundle)
      # localize contents below vendor/*/*/ input directory
      ::Dir.chdir("./vendor/#{in_bundle}/") do
        FileUtils.cp_r(glob("./*"), build_path)
      end
      lock = parse_lock("composer.lock", in_bundle)
    else
      # download one package (and dependencies, which are thrown away afterwards)
      ::Dir.chdir(staging_path) do
        ver = attributes[:composer_ver]
        safesystem(
          composer, "require", "--prefer-dist", "--update-no-dev", "--ignore-platform-reqs",
          "--no-ansi", "--no-interaction", in_bundle, *(ver ? [ver] : [])
        )
        # localize Vnd/Pkg folder
        lock = parse_lock("composer.lock", in_bundle)
        FileUtils.mv(glob("./vendor/#{in_bundle}/#{lock[in_bundle]['target-dir']}/*"), build_path)
        FileUtils.rm_r(glob("#{staging_dir}/*"))
      end
    end
    
    # prepare assembly
    composer_json_import(lock[in_bundle])
    target_dir = lock["target-dir"] or in_bundle
    attributes[:phar_format] = "zip+gz" unless attributes[:phar_format_given?]


    #-- staging
    # eventually move this to convert() or converted_from()..
    
    # system package (deb/rpm) with raw files under /usr/share/php/Vnd/Pkg
    if !@as_phar
      @name_prefix = "php-"
      attributes[:prefix] ||= "/usr/share/php/#{target_dir}"
      FileUtils.mkdir_p(dest = "#{staging_path}/#{@attributes[:prefix]}")
      FileUtils.mv(glob("#{build_path}/*"), dest)

    # matroska phar-in-deb/rpm, ends up in /usr/share/php/*.phar
    elsif attributes[:composer_phar_given?]
      @name_prefix = "phar-"
      FileUtils.mkdir_p(staging_dest = "#{staging_path}/usr/share/php")
      ::Dir.chdir("#{build_path}") do
        phar = convert(FPM::Package::Phar)
        phar.instance_variable_set(:@staging_path, ".")
        phar.output("#{staging_dest}/#{@name}.phar");
        phar.cleanup_build
      end

    # becomes local -t phar
    else
      cleanup_staging
      @staging_path = build_path
    end

    cleanup_build
    @name = "#{@name_prefix}#{@name}"
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
  def parse_lock(fn, in_bundle)
    json = JSON.parse(File.read(fn))
    if !json.key? "packages"
      json["packages"] = []
    end
    if json.key? "packages-dev"
      json["packages"] += json["packages-dev"]
    end
    lock = Hash[  json["packages"].map{ |entry| [entry["name"], entry] }  ]
    unless lock.key? in_bundle
      raise FPM::InvalidPackageConfiguration, "Package name #{in_bundle} absent in composer.lock"
    end
    return lock
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

  def glob(path)
    ::Dir.glob(path)
  end

end # class ::Composer
