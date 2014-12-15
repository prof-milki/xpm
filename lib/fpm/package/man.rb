
# api: fpm
# title: manpage compression
# description: Compresses any man/* pages in the build path
# type: delegate
# category: filter
# version: 0.1
# license: MITL
# 
# Simply compresses any manpages in the build path.
# Only looks for files with uncategorized ….1 / ….5 suffixes.
#

require "fpm/package"
require "fpm/util"

# find manpages, compress them
class FPM::Package::Man < FPM::Package
  def update
    ::Dir[staging_path + "/**/man/**/*.[12345678]"].each do |file|
       safesystem("gzip", "-9", file)
    end
  end
end
