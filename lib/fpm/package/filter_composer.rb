#
# api: fpm
# title: Composer.json stub
# description: injects/updates a composer.json from fpm attributes
# type: template
# depends: json
# category: meta
# doc: https://getcomposer.org/doc/04-schema.md
# version: 0.1
#
# Adapts or creates a composer.json from fpm/package attributes.
#
#  → To be used in conjunction with -t phar plugin, to craft a whole
#    composer bundle from plain scripts.
# 

require "fpm/package"
require "fpm/util"
require "json"
require "fileutils"
require "time"

# composer.json
class FPM::Package::Filter_Composer < FPM::Package
  def update
    # read existing data
    dest = "#{staging_path}/#{@prefix}/composer.json"
    if File.exist?(dest)
      json = JSON.parse(File.read(dest))
      p json
      # technically it could also become an input filter now,
      # injecting known values for absent fpm attributes here
      # (only had to be transferred back to @input in command.rb then..)
    else
      # create afresh
      json = {
        "name" => "#{@name}/#{@name}",
        "description" => @description,
        "license" => @license,
        "homepage" => @url,
        "type" => "library",
        "extra" => {
          "\$packaged-by" => "xpm/fpm",
          "maintainer" => @maintainer,
          "epoch" => @epoch,
          "releases"=> []
        },
        "autoload" => {
          "shared" => ["#{@name}.phar"]
        }
      }
    end
    # update current build information
    json.merge!({        
      "version" => @version,
      "time" => Time.now.strftime("%Y-%m-%d"),
      "bin" => bin()
    })
    # save `composer.json` to staging path
    File.write(dest, JSON.pretty_generate(json))
  end

  def bin
    ::Dir.chdir(staging_path) do
      return ::Dir.glob("**").keep_if { |fn| File.executable?(fn) and not File.directory?(fn) }
    end
  end
end
