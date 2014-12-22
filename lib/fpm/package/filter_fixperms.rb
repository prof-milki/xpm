# Set file permissions to 644/755 maximum

require "fpm/package"
require "fpm/util"
require "fileutils"

class FPM::Package::Filter_fixperms < FPM::Package
  def update(opts=nil)
    ::Dir["#{staging_path}/**/*"].each do |fn|
      File.chmod(File.stat(fn).mode & 0777755, fn)
    end
  end
end
