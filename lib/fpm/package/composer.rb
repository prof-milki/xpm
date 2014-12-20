
# api: fpm
# title: Composer source
# description: Downloads composer bundles into system or phar packages
# type: package
# category: source
# version: 0.1
# state: experimental
# license: MITL
# author: mario#include-once:org
# 
# Fetches packagist bundles, allows fpm to package them as
# system (deb/rpm) or phar packages, or matroska phar-in-deb
# packages even.
#
# → Invokes `composer archive` for raw downloads
# → Afterwards stages input per zip module
# ø Unclear: require/use `-u composer` for reading meta?
# → Variant: prepackage as -t phar? ('d preclude filoloaders)
# → system packs require manual composer.json assembly/update,
#   as composer can't reconstruct them or its .lock from dirs.
# → fpm only works on bundle-by-bundle basis, doesn't package
#   up multiple dependencies implicitly (=> wrapper call ?)
#
# Composer bundles go into /usr/share/php/vendor/vnd/pkg/*.*
# where composer.json/lock ought to be updated from. The vendor/
# prefix is retained and enforced to prevent clashes with PEAR
# and system packages.
#
# Phar bundles can go directly into /usr/share/php/vnd-pkg.phar,
# because there's no filesystem overlap to be expected.
# (Needs a contemporary autoloader; albeit unadulterated packss
# won't run speedier than with PSR-0/4 file-by-file loaders.)
#

require "fpm/package"
require "fpm/util"
require "fpm/package/zip"
require "fileutils"
require "json"


# Composer reading (source only)
class FPM::Package::Composer < FPM::Package

  option "--ver", "\@trunk", "Which version to checkout", :default=>""
  option "--phar", :bool, "Convert bundle into local .phar plugin package", :default=>false

  # uncover composer  
  def initialize
    @composer = (`which composer` or `which composer.phar` or ("php "+`locate composer.phar`)).split("\n").first
    super
  end

  # fetch and expand composer download
  def input(in_bundle)

    # general params
    @as_phar = attributes[:composer_phar] || attributes[:output_type].match(/phar/)
    @name = (@as_phar ? "" : "php-composer-") + in_bundle.gsub(/\W+/, '-')
    attributes[:prefix] = "/usr/share/php/vendor/#{in_bundle}" unless @as_phar
    @architecture = "all"
    @vendor = in_bundle.split(/\W/).first

    # retrieve and expand zip archive
    ::Dir.chdir(build_path) do
      safesystem(@composer, "archive", "--format=zip", in_bundle) # attributes[:composer_ver]
      download = ::Dir["#{build_path}/*.zip"].first
      zip = convert(FPM::Package::Zip)
      zip.input(download)
      zip.cleanup_build
      FileUtils.rm(download)
      cleanup_build
    end

    # subsume composer.json
    if File.exist?(cj = "#{staging_path}/#{attributes[:prefix]}/composer.json")
      cj = JSON.parse(File.read(cj))
      map = { "description" => "\@description", "version" => "\@version", "license" => "\@license", "homepage" => "\@homepage", "authors" => "\@maintainer" }
      map.each do |from, to|
        if cj.key?(from)
          instance_variable_set(to, [cj[from]].flatten.join(", "))
        end
      end
      if cj.key?("require")
        @dependencies = cj["require"].collect { |k,v| require_convert(k,v) }
      end
    end

    # pre-package as local-phar - meant for .phar in deb/rpm system package - else just use a regular -t phar target
    if attributes[:composer_phar]
      attributes[:phar_format] = "zip+gz"
      phar = convert(FPM::Package::Phar)
      fn = phar.build_path + "/#{@name}.phar"
      phar.output(fn)
      phar.cleanup_staging
      FileUtils.rm_rf(staging_path + "/.")
      FileUtils.mkdir_p(staging_path + "/usr/share/php/")
      FileUtils.mv(fn, staging_path + "/usr/share/php/")
    else
      # register /usr/share/php/composer.json update script here
      # (composer can't rescan on its own.)
      #attributes[:after_install] = ...
    end
  end # def output

  
  # transpose package string special valus, or bunldes/forks into system package names
  def require_convert(k, v)
    if k == "php" #-64/32bit
      k = @as_phar ? k : k
    elsif k =~ /^ext-(\w+)$/
      k = @as_phar ? "php:$1" : "php-$1"
#   elsif k =~ /^lib-(\w+)$/
    else
      k =(@as_phar ? "" : "php-composer-") + k.gsub(/\W+/, '-')
    end
    return "#{k} (#{v})"
  end

end # class ::Composer
