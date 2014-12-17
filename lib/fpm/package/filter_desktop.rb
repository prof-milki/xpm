#
# api: fpm
# title: .desktop files
# description: Generates a pkg.desktop files
# type: template
# depends: erb
# category: meta
# version: 0.1
#
# Creates a /usr/share/applications/PKGNAME.desktop file if absent.
#

require "fpm/package"
require "fpm/util"
require "fileutils"
require "erb"

# create .desktop file
class FPM::Package::Filter_desktop < FPM::Package

  include ERB::Util

  def update
    dest = "#{staging_path}/usr/share/applications/fpm:#{name}.desktop"
    FileUtils.mkdir_p(File.dirname(dest))
p dest
    File.open(dest, "w") do |ini|
p      ini.write template("desktop.erb").result(binding)
    end
  end

end
