# encoding: utf-8
# api: fpm
# title: Listaller IPK
# description: generates Listaller packages using lipkgen
# type: package
# category: target
# version: 0.0
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
    p ipk
    ::Dir.mkdir(ipk)
    # options file
    File.open("#{ipk}/pkoptions", "w") do |f|
      f.write template("listaller/pkoptions.erb").result(binding)
    end
    # write DOAP
    File.open("#{ipk}/#{name}.doap", "w") do |f|
      f.write template("listaller/doap.erb").result(binding)
    end
    # file list
    File.open("#{ipk}/files-all.list", "w") do |f|
      f.write template("listaller/files.erb").result(binding)
    end
    # stubs
    File.open("#{ipk}/build.rules", "w") do |f|
    end
    File.open("#{ipk}/dependencies.list", "w") do |f|
    end
    
    # let the packaging be done
    sign = attributes[:deb_sign] ? ["--sign"] : []
    ::Dir.chdir(staging_path) do
      system(
        "lipkgen",
        "-b",
        *sign,
        "--verbose",
        "--sourcedir=.",
        "--outdir=#{build_path}"
      )
    end
    
    # move file
    File.rename(::Dir["#{build_path}/*.ipk"].first, output_path)
  end # output

end
