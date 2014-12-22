# encoding: utf-8
# api: fpm
# title: Listaller IPK
# description: generates Listaller packages using lipkgen
# type: package
# category: target
# version: 0.1
# doc: http://listaller.tenstral.net/docs/chap-Listaller-Packaging.html
# depends: bin:lipkgen, erb
#
# Listaller uses .IPK files for cross-distro installations. It's well
# integrated with Freedesktop schemes and distro application managers.
# 
# This module just chains to the generation tool currently, and builds
# static / unrelocatable packages. (Proper support would require using
# Listallers relaytool + ligcc when building the app binaries.)
#

require "fpm/package"
require "fpm/util"
require "fileutils"
require "erb"
require "time"

# Build Listaller package
class FPM::Package::IPK < FPM::Package

  include ERB::Util

  option "--relocatable", :bool, "Assume application was built relocatable."

  # Create doap, files list, then package up
  def output(output_path)
    output_check(output_path)

    # pre-generate files list
    files = []
    ::Dir.chdir(staging_path) do
      files = ::Dir["**/*"]
    end
    
    # set up build path
    ipk = "#{staging_path}/ipkinstall"
    ::Dir.mkdir(ipk)
    File.open("#{ipk}/pkoptions", "w") do |f|
      f.write template("listaller/pkoptions.erb").result(binding)
    end
    File.open("#{ipk}/#{name}.doap", "w") do |f|
      f.write template("listaller/doap.erb").result(binding)
    end
    File.open("#{ipk}/files-#{architecture}.list", "w") do |f|
      f.write template("listaller/files.erb").result(binding)
    end
    File.open("#{ipk}/build.rules", "w") do |f|
    end
    File.open("#{ipk}/dependencies.list", "w") do |f|
    end
    
    # let the packaging be done
    opts = ["-b", "--sourcedir=.", "--outdir=#{build_path}"]
    if attributes[:deb_sign] || attributes[:rpm_sign]
      opts << "--sign"
    end
    if @verbose || @debug
      opts << "--verbose"
    end
    ::Dir.chdir(staging_path) do
      safesystem("lipkgen", *opts);
    end
    FileUtils.rm_rf(ipk) unless attributes[:debug?]
    
    # move file
    File.rename(::Dir["#{build_path}/*.ipk"].first, output_path)
  end # output

end
