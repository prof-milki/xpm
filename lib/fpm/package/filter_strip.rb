# Strip binaries

require "fpm/package"
require "fpm/util"
require "fileutils"

class FPM::Package::Filter_strip < FPM::Package
  def update
    ::Dir["#{staging_path}/**/*"].each do |fn|
      if (not File.directory?(fn)) && File.executable?(fn) #|| fn =~ /\.so$/
        system("ls", "-l", fn)
        safesystem("strip", fn)
      end
    end
  end
end
