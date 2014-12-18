# Strip debugging symbols from binaries,
# ignore shared libs

require "fpm/package"
require "fpm/util"
require "fileutils"

class FPM::Package::Filter_strip < FPM::Package
  def update
    ::Dir["#{staging_path}/**/*"].each do |fn|
      unless File.directory?(fn)
        # only work on ELF files
        if File.read(fn, 4) != "\x7FELF"
          next
        elsif File.executable?(fn)
          safesystem("strip", fn)
        elsif fn =~ /\.so$/
          # don't strip libs
          #safesystem("strip", fn)
        end
      end
    end
  end
end
