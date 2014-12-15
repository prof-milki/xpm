#
# api: fpm
# title: AppData/AppStream
# description: Generates a pkg.appdata.xml for distribution package managers
# type: template
# depends: erb
# category: meta
# doc: http://en.wikipedia.org/wiki/AppStream, http://people.freedesktop.org/~hughsient/appdata/
# version: 0.2
#
# Creates a /usr/share/appdata/PKGNAME.appdata.xml file for consumption by
# distribution package managers.
#
#  → The point of which is to embed a shared screenshot and lookup user
#    reviews/ratings. (At least should benefit appcenter listings.)
#  → Only use this filter (-u appdata) if you're not already including a
#    custom appdata.xml file.
#  → See also the advised description style in the AppData spec.
#  → Primarily meant for desktop applications.
# 
# This plugin will write to the default usr/share/appdata/ location in the staging
# path regardless of --prefix.
#
# BUGS:
#  - Does not yet escape XML properly.
#  - Doesn't split up description into <p> and <ul> sections (or store lang=).
#  - Stub screenshot used, we might need a new --screenshot flag.
#

require "fpm/package"
require "fpm/util"
require "fileutils"
require "erb"

# create appdata.xml file
class FPM::Package::Appdata < FPM::Package

  include ERB::Util

  def update
    dest = "#{staging_path}/usr/share/appdata/#{name}.appdata.xml"
    FileUtils.mkdir_p(File.dirname(dest))
    File.open(dest, "w") do |xml|
      xml.write template("appstream.erb").result(binding)
    end
  end

end
