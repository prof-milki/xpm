# encoding: utf-8
# api: fpm
# title: Composer source
# description: Downloads composer bundles into system or phar packages
# type: package
# category: source
# version: 0.2
# state: beta
# license: MITL
# author: mario#include-once:org
# 
# Creates system packages for composer/packagist bundles.
#
#  → Either works on individual vendor/*/*/ dirs as input-
#
#  → Or downloads and extrudes a single vnd/pkgname bundle.
#
# And supports different target variations:
#
#  → Syspackage bundles end up in /usr/share/php/vendor/vnd/pkg/.
#    The composer.json is augmented with lock[] data to permit
#    rebuilding composer.lock and file-autoloading.
#
#  → Whereas --composer-phar creates Phars matroska`d into system
#    packages, that go into /usr/share/php/vnd-pkg.phar.
#
#  → With a standard `-t phar` it'll just compact individual
#    components into local-path phars.
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
#

require "fpm/package"
require "fpm/util"
require "fpm/package/zip"
require "fileutils"
require "json"


# Composer reading (source only)
class FPM::Package::Composer < FPM::Package

  option "--ver", "\@trunk", "Which version to checkout", :default=>nil
  option "--phar", :flag, "Convert bundle into local .phar plugin package", :default=>false

  def initialize
    super
    @architecture = "all"
    @as_phar = false
  end

  # fetch and expand composer download
  def input(in_bundle)

    # general params
    as_phar = attributes[:composer_phar_given?] || attributes[:output_type].match(/phar/)
    in_bundle = in_bundle.gsub(/^(.\/)*vendor\/+|\/(?=\/)|\/+$/, "")
    @name = in_bundle.gsub(/[\W]+/, "-")
    lock = {}
    target_dir = ""

    # operation mode
    if File.exist?("vendor/" + in_bundle)
      # prepare a single vendor/*/* input directory
      FileUtils.cp("composer.lock", build_path)
      FileUtils.mkdir_p(dest = "#{build_path}/vendor/#{in_bundle}")
      FileUtils.cp_r(::Dir.glob("./vendor/#{in_bundle}/*"), dest)
    else
      # download one package (and dependencies, which are thrown away afterwards)
      ::Dir.chdir(build_path) do
        ver = attributes[:composer_ver]
        safesystem(composer, "require", "--ignore-platform-reqs", in_bundle, *(ver ? [ver] : []))
        FileUtils.rm_r(["vendor/composer", "vendor/autoload.php"])
      end
    end

    # extract composer lock{} list, update fpm meta fields, and merge into pkgs` composer.json
    ::Dir.chdir(build_path) do
      lock = parse_lock("composer.lock")
      target_dir = lock[in_bundle]["target-dir"]
      inject_lock("vendor/#{in_bundle}/#{target_dir}/composer.json", lock[in_bundle])
      composer_json_import(lock[in_bundle])
    end

    #-- staging
    
    # system package (deb/rpm) with raw files under /usr/share/php/vendor/
    if !as_phar
      @name = "php-composer-#{name}"
      attributes[:prefix] ||= "/usr/share/php/vendor/#{in_bundle}"
      FileUtils.mkdir_p("#{staging_path}/usr/share/php")
      FileUtils.mv("#{build_path}/vendor", "#{staging_path}/usr/share/php")

    # phar packages, lose deep nesting
    else
      build_deep = "#{build_path}/vendor/#{in_bundle}/#{target_dir}"
      attributes[:phar_format] = "zip+gz" unless attributes[:phar_format_given?]

      # becomes local -t phar
      if attributes[:output_type] == "phar"
        FileUtils.mv(::Dir.glob("#{build_deep}/*"), staging_path)

      # matroska phar-in-deb/rpm, ends up in /usr/share/php/*.phar
      else
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

    #
    #if as_phar
    #  attributes[:prefix] = "/usr/share/php/vendor/#{in_bundle}"
    #else
    #  name = "php-composer-" + in_bundle.gsub(/\W+/, '-')
    #end
    # pre-package as local-phar - meant for .phar in deb/rpm system package - else just use a regular -t phar target
    #if attributes[:composer_phar]
    #  attributes[:phar_format] = "zip+gz"
    #  phar = convert(FPM::Package::Phar)
    #  fn = phar.build_path + "/#{@name}.phar"
    #  phar.output(fn)
    #  phar.cleanup_staging
    #  FileUtils.rm_rf(staging_path + "/.")
    #  FileUtils.mkdir_p(staging_path + "/usr/share/php/")
    #  FileUtils.mv(fn, staging_path + "/usr/share/php/")
    #else
      # register /usr/share/php/composer.json update script here
      # (composer can't rescan on its own.)
      #attributes[:after_install] = ...
    #end
    rescue StandardError => e
      p e
  end # def output

  
  # transpose package string magic values, or bundles/forks into system package names
  def require_convert(k, v)
    if ["php", "php-32bit", "php-64bit", "hhvm", "quercus"].include?(k)
      k = "php5"
    elsif k =~ /^ext-(\w+)$/
      k = @as_phar ? "php:$1" : "php5-$1"
    elsif k =~ /^lib-(\w+)$/
      k = @as_phar ? "sys:lib$1" : "lib$1"
    else
      k =(@as_phar ? "" : "php-composer-") + k.gsub(/\W+/, '-')
    end
    return "#{k} (#{v})"
  end

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
      @dependencies = json["require"].collect { |k,v| require_convert(k,v) }
    end
  end

  # Extract package sections from composer.lock file, turn into pkgname→hash
  def parse_lock(fn)
    json = JSON.parse(File.read(fn))
    FileUtils.rm(fn)  # not needed afterwards (this is run within the build_path)
    Hash[  json["packages"].map{ |entry| [entry["name"], entry] }  ]
  end
  
  def inject_lock(fn, extra)
    json = JSON.parse(File.read(fn))
    json["extra"] ||= {}
    json["extra"]["lock"] = extra
    File.write(fn, JSON.pretty_generate(json))
  end

  # find composer binary
  def composer
    (`which composer` or `which composer.phar` or ("php "+`locate composer.phar`)).split("\n").first
  end

end # class ::Composer
