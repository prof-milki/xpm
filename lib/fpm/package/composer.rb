#
# encoding: utf-8
# api: fpm
# title: Composer source
# description: Converts composer bundles into system or/and phar packages
# type: package
# depends: bin:composer
# category: source
# version: 0.5
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
#  → While a standard `-t phar` target will just compact individual
#    components into localized phars.
#
# NOTES
#
# → Currently rewritten to conform to Debian pkg-php-tools and Fedora
#   schemes.
# → The vendor/ extraction prefix isn't retained any longer. Composer wasn't
#   meant to manage system-globally installed libraries.
# → System packages thus need a global autoloader (shared.phar / phpab)
#   or manual includes.
# → The build process utilizes `composer require` to fetch new packages,
#   if xpm -s composer isn't run from within a composer managed project.
# → Bring in line with Debian packaging scheme, dh_phpcomposer/pkg-php
#   dropped -composer- in package names, got rid of nested /vendor/deep/dirs/
#   yet to adopt complete version/dependency translation after all?
# ø Dependencies are neither in line with Fedora/RPM version expressions,
#   http://fedoraproject.org/wiki/Packaging:PHP
#   https://twiki.cern.ch/twiki/bin/view/Main/RPMAndDebVersioning
# ø Unclear: require/use `-u composer` for reading meta? Currently just
#   composer.lock is scanned for input.
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
    @once = false          # prevent double .input() invocation
  end

  # download composer bundle, or compact from existing vendor/ checkout
  def input(vnd_pkg_path)

    # general params
    in_bundle = vnd_pkg_path.gsub(/^(.+\/+)*vendor\/+|\/(?=\/)|\/+$/, "")
    @name = in_bundle.gsub(/[\W]+/, "-")
    json = {}
    if @once
      @once = true
      raise FPM::InvalidPackageConfiguration, "You can't input multiple bundle names. Only one package can be built at a time currently. Use a shell loop please."
    elsif in_bundle =~ /^composer\/\w+\.\w+/
      raise FPM::InvalidPackageConfiguration, "composer/*.* files specified as input. Supply only one bundle id."
    end

    # copying mode
    if File.exist?("vendor/" + in_bundle)
      json = parse_lock("composer.lock", in_bundle)[in_bundle]
      # localize contents below vendor/*/*/ input directory
      ::Dir.chdir("./vendor/#{in_bundle}/#{json['target-dir']}/") do
        FileUtils.cp_r(glob("./*"), build_path)
      end
    else
      # download one package (and dependencies, which are thrown away afterwards)
      ::Dir.chdir(staging_path) do
        ver = attributes[:composer_ver]
        safesystem(
          composer, "require", "--prefer-dist", "--update-no-dev", "--ignore-platform-reqs",
          "--no-ansi", "--no-interaction", in_bundle, *(ver ? [ver] : [])
        )
        # localize Vnd/Pkg folder
        json = parse_lock("composer.lock", in_bundle)[in_bundle]
        FileUtils.mv(glob("./vendor/#{in_bundle}/#{json['target-dir']}/*"), build_path)
        FileUtils.rm_r(glob("#{staging_path}/*"))
      end
    end

    #-- staging
    # At this point the build_path contains just the actual class files, etc.
    # Conversion to sys/phar/sysphar is handled in convert() along with the
    # dependency translation.
    composer_json_import(json)
    @target_dir = json.include?("target-dir") ? json["target-dir"] : in_bundle
    attributes[:phar_format] = "zip+gz" unless attributes[:phar_format_given?]
  end # def output

  
  def convert(klass)
    pkg = super(klass)

    # becomes local -t phar
    if klass == FPM::Package::Phar
      pkg.instance_variable_set(:@staging_path, build_path)
      @name_prefix = ""  # needs to be reset in case of multi-target building

    # prepare matroska phar-in-deb/rpm, ends up in /usr/share/php/*.phar
    elsif attributes[:composer_phar_given?]
      FileUtils.mkdir_p(staging_dest = "#{staging_path}/usr/share/php")
      ::Dir.chdir("#{build_path}") do
        phar = convert(FPM::Package::Phar) # will loop internally
        phar.output("#{staging_dest}/#{@name}.phar");
      end
      @name_prefix = "phar-"

    # system package (deb/rpm) with plain files under /usr/share/php/Vnd/Pkg
    else
      dest = "/usr/share/php/#{@target_dir}"
      FileUtils.mkdir_p(dest = "#{pkg.staging_path}/#{dest}")
      FileUtils.cp_r(glob("#{build_path}/*"), dest)
      @name_prefix = "php-"
    end

    # add dependencies
    pkg.name = "#{@name_prefix}#{@name}"
    pkg.dependencies += @cdeps.collect { |k,v| require_convert(k, v, @name_prefix, klass) }.flatten.compact
    return pkg
  end # def convert


  # translate package names and versions
  def require_convert(k, v, prefix, klass)

    # package type/name maps
    map = { FPM::Package::RPM => :rpm, FPM::Package::Deb => :deb, FPM::Package::Phar => :phar }
    typ = map.include?(klass) ? map[klass] : :deb
    pn = {
      :php => { :phar => "php",     :deb => "php5-common", :rpm => "php(language)" },
      :ext => { :phar => "ext:",    :deb => "php5-",       :rpm => "php-" },
      :lib => { :phar => "sys:lib", :deb => "lib",         :rpm => "lib" },
      :bin => { :phar => "bin:",    :deb => "",            :rpm => "/usr/bin/" }
    }

    # package names, magic values
    case k = k.strip.gsub(/\W+/, "-")
      when /^php(-32bit|-64bit)?|^hhvm|^quercus/
        k = pn[:php][typ]
        @architecture = ($1 == "-32bit") ? "x86" : "amd64" if $1
      when /^(ext|lib|bin)-(\w+)$/
        k = pn[$1.to_sym][typ] + $2
      else
        k = prefix + k
    end

    # expand version specifiers (this is intentionally incomplete)
    if attributes[:no_depends_given?]
      v = ""
    else
      v = v.split(",").map {
        |v|
        case v = ver(v, typ)
          when "*"
            ""
          when /^[\d.-]+~*$/  # 1.0.1
            " = #{v}"
          when /^((\d+\.)*(\d+))\.\*/  # 1.0.*
            [" >= #{$1}.0", " <= #{$1}.999"]
          when /^([!><=]*)([\d.-]+~*)$/  # >= 2.0   # debianize_op() normalizes >, <, = anyway
            " #{$1} #{$2}"
          when /^~\s*([\d.-]+~*)$/  # ~2.0   # deb.fix_dependency translates that into a range ["pkg(>=1)", "pkg(<<2)"]
            " ~> #{$1}"
          else
            ""
        end
      }
    end
    return k ? v.flatten.map { |v| k + v } : nil
  end
  
  # normalize version strings to packaging system
  def ver(v, typ)
    v.gsub!(/ (?:^.+ \sAS\s (.+$))? | \s+() | ^v() /nix, "\\1")
    case typ
      when :deb
        v.gsub!(/[-@](dev|patch).*$/, "~~")
        v.gsub!(/[-@](alpha|beta|RC|stable).*$/, "~")
      when :rpm
        v.gsub!(/[-@](dev|patch|alpha|beta|RC|stable).*$/, "")
      else
        v.gsub!(/@/, "-")
    end
    return v
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
      @cdeps = json["require"]
    end
    # stash away complete composer struct for possible phar building
    @attrs[:composer] = json
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
      raise FPM::InvalidPackageConfiguration, "Package name '#{in_bundle}' absent in composer.lock"
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
