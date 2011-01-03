#!/usr/bin/env ruby
#

require "optparse"
require "ostruct"
require "erb"

def main(args)
  settings = OpenStruct.new

  opts = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"
    
    opts.on("-p PACKAGEFILE", "--package PACKAGEFILE",
            "The package file to manage") do |path|
      if path =~ /^\//
        settings.package_path = path
      else
        settings.package_path = "#{Dir.pwd}/#{path}"
      end
    end

    opts.on("-n PACKAGENAME", "--name PACKAGENAME",
            "What name to give to the package") do |name|
      settings.package_name = name
    end

    opts.on("-v VERSION", "--version VERSION",
            "version to give the package") do |version|
      settings.version = version
    end

    opts.on("-d DEPENDENCY", "--depends DEPENDENCY") do |dep|
      settings.dependencies ||= []
      settings.dependencies << dep
    end

    opts.on("-a ARCHITECTURE", "--architecture ARCHITECTURE") do |arch|
      settings.architecture = arch
    end

    opts.on("-m MAINTAINER", "--maintainer MAINTAINER") do |maintainer|
      settings.maintainer = maintainer
    end

    opts.on("-C DIRECTORY", "Change directory before searching for files") do |dir|
      settings.chdir = dir
    end
  end # OptionParser

  opts.parse!(args)

  # Actions:
  # create package
  #
  # files: add, remove
  # scripts: add, remove
  # metadata: set, add, remove

  if !settings.package_path
    $stderr.puts "No package file given to manage. Give with -p PACKAGEFILE"
    return 1
  end

  paths = args
  type = settings.package_path.split(".")[-1]

  mkbinding = lambda do
    package = settings.package_name
    version = settings.version
    package_iteration = 1

    maintainer = (settings.maintainer or "<#{ENV["USER"]}>")
    category = (settings.category or "X11")
    summary = (settings.summary or "no summary given for #{package}-#{version}")

    architecture = (settings.architecture or %x(uname -m).chomp)
    if architecture == "x86_64" && type == "deb"
      architecture = "amd64"
    end


    url = (settings.url or "http://example.com/")
    dependencies = (settings.dependencies or [])
    return binding
  end

  metadata = mkbinding.call

  package_path = settings.package_path
  package_path.gsub!(/VERSION/, eval('"#{version}-#{package_iteration}"', metadata))
  package_path.gsub!(/ARCH/, eval("architecture", metadata))


  if type != "deb"
    $stderr.puts "Unsupported package type '#{type}'"
    return 1
  end


  builddir = "#{Dir.pwd}/build-#{type}-#{File.basename(package_path)}"
  Dir.mkdir(builddir) if !File.directory?(builddir)
  template = File.new("#{File.dirname(__FILE__)}/../templates/#{type}.erb").read()

  Dir.chdir(settings.chdir || ".") do 
    puts Dir.pwd

    # Add directories first.
    dirs = []
    paths.each do |path|
      while path != "/" and path != "."
        if !dirs.include?(path) or File.symlink?(path)
          dirs << path 
        else
          #puts "Skipping: #{path}"
          #puts !dirs.include?(path) 
          #puts !File.symlink?(path)
        end
        path = File.dirname(path)
      end
    end
    dirs = dirs.sort { |a,b| a.length <=> b.length}
    puts dirs.join("\n")
    system(*["tar", "--owner=root", "--group=root", "-cf", "#{builddir}/data.tar", "--no-recursion", *dirs])
    puts paths.join("\n")
    #paths = paths.reject { |p| File.symlink?(p) }
    system(*["tar", "--owner=root", "--group=root", "-rf", "#{builddir}/data.tar", *paths])
    system(*["gzip", "-f", "#{builddir}/data.tar"])

    # Generate md5sums
    md5sums = []
    paths.each do |path|
      md5sums += %x{find #{path} -type f -print0 | xargs -0 md5sum}.split("\n")
    end
    File.open("#{builddir}/md5sums", "w") { |f| f.puts md5sums.join("\n") }

    # Generate 'control' file
    control = ERB.new(template).result(metadata)
    File.open("#{builddir}/control", "w") { |f| f.puts control }
  end

  # create control.tar.gz
  Dir.chdir(builddir) do
    system("tar -zcf control.tar.gz control md5sums")
  end

  Dir.chdir(builddir) do
    # create debian-binary
    File.open("debian-binary", "w") { |f| f.puts "2.0" }
  end

  Dir.chdir(builddir) do
    system("ar -qc #{package_path} debian-binary control.tar.gz data.tar.gz")
  end
end

ret = main(ARGV) 
exit(ret != nil ? ret : 0)
