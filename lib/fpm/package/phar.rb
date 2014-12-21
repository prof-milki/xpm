
# api: fpm
# title: PHP Phar target
# description: Chains to PHP for creating a .phar (native/tar/zip) archive
# type: package
# category: target
# version: 0.2
# state: very alpha
# license: MITL
# author: mario#include-once:org
# 
# This packaging target generates simple PHP Phar assemblies. With its
# default stub assuming `__init__.php` for CLI applications, and `index.php`
# as web router. A custom --phar-stub can be set of course.
#
# It honors the output filename, but alternatively allows `--phar-format`
# overriding the packaging format. It flexibly recognizes any concatenation
# of „phar·zip·tar“ with „gz·bz2“, case-insensitively.
#
#  ┌─────────────┬─────────────┬─────────────┬─────────────┬───────────────┐
#  │ Extension   │ Archive     │ Compression │ Envelope    │ Use           │
#  │ / Specifier │ Format      │ Per File    │ Compression │ Cases         │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ phar        │ Phar        │ -           │ -           │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ phar.gz     │ Phar        │ gzip        │ -           │ general       │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ phar·bz2    │ Phar        │ bzip2       │ -           │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ PHAZ        │ Phar        │ -           │ gzip        │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ -           │ Phar        │ gzip        │ gzip        │ (eschew)      │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ zip         │ Zip         │ -           │ -           │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ zip.gz      │ Zip         │ gzip        │ -           │ distribution  │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ zip…bz2     │ Zip         │ bzip2       │ -           │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ tar         │ Pax         │ -           │ -           │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ tgz         │ Pax         │ -           │ gzip        │               │
#  ├─────────────┼─────────────┼─────────────┼─────────────┼───────────────┤
#  │ tar+bz2     │ Pax         │ -           │ bzip2       │ data bundles  │
#  └─────────────┴─────────────┴─────────────┴─────────────┴───────────────┘
#
# ZIPs and TARs can be read by other languages, but contain PHP/phar-specific
# additions (.phar/stub and a signature).
#

require "fpm/package"
require "fpm/util"
require "fileutils"
require "json"

# Phar creation (output only)
class FPM::Package::Phar < FPM::Package

  option "--format", "PHAR.gz/TGZ/ZIP", "Phar package type and compression (append .gz/.bz2 for method)", :default=>"PHAR.GZ"
  option "--stub", "STUB.php", "Apply initialization/stub file", :default=>""
  #option "--nocase", :flag, "Lowercase filenames within archive", :default=>false
  option "--sign", "PEM_FILE", "Sign package with OpenSSL and key from .pem file", :default=>""

  # Invoke PHP for actual packaging process
  def output(output_path)

    # Flags
    o_nocase = attributes[:phar_nocase] || false
    o_stub = attributes[:phar_stub] || ""
    o_sign = attributes[:phar_sign] || ""
    
    # Retain package meta information, either from fpm attributes, or collected :meta hash (src module)
    meta = attributes[:meta] || {
      "id" => @name,
      "version" => @version.to_s,
      "epoch" => @epoch.to_s,
      "iteration" => @iteration.to_s,
      "architecture" => @architecture,
      "category" => @category == "none" ? nil : @category,
      "author" => @maintainer,
      "url" => @url,
      "license" => @license,
    }
    meta = meta.delete_if{ |k,v| v.nil? || v==""}
    
    # Match format specifier/extension onto type/settings
    fmt = (attributes[:phar_format] + output_path).downcase
    fmt, enc = fmt.match(/zip|phaz|tar|t[gb]z|pz/).to_s||"phar", fmt.match(/gz|bz2/).to_s
    map2 = { "tgz" => ["tar", "gz"], "tbz" => ["tar", "bz2"], "pz" => ["phaz", ""]  }
    map = {
        # fmt,  enc          extension   format        per-file-gz   extns ← archive-compr
       ["phar", ""   ] => [ ".phar",     "Phar::PHAR", "Phar::NONE", "",     "" ],
       ["phar", "gz" ] => [ ".phar",     "Phar::PHAR", "Phar::GZ",   "",     "" ],
       ["phar", "bz2"] => [ ".phar",     "Phar::PHAR", "Phar::BZ2",  "",     "" ],
       ["zip",  ""   ] => [ ".phar.zip", "Phar::ZIP",  "Phar::NONE", "",     "" ],
       ["zip",  "gz" ] => [ ".phar.zip", "Phar::ZIP",  "Phar::GZ",   "",     "" ],
       ["zip", "bz2" ] => [ ".phar.zip", "Phar::ZIP",  "Phar::BZ2",  "",     "" ],
       ["tar",  ""   ] => [ ".phar.tar", "Phar::TAR",  "Phar::NONE", "",     "" ],
       ["tar",  "gz" ] => [ ".phar.tar", "Phar::TAR",  "Phar::GZ",   ".gz",  "(Phar::GZ)" ],
       ["tar", "bz2" ] => [ ".phar.tar", "Phar::TAR",  "Phar::BZ2",  ".bz2", "(Phar::BZ2)"],
       ["phaz", ""   ] => [ ".phar",     "Phar::PHAR", "Phar::GZ",   ".gz",  "(Phar::GZ)" ],
       ["phaz", "gz" ] => [ ".phar",     "Phar::PHAR", "Phar::GZ",   ".gz",  "(Phar::GZ)" ],
       ["phaz", "bz2"] => [ ".phar",     "Phar::PHAR", "Phar::GZ",   ".bz2", "(Phar::BZ2)"],
    }
    opt = map[[fmt,enc]] || map[map2[fmt]] || map[["phar", ""]]
    o_stdext, o_format, o_filegz, o_extout, o_hullgz = opt
    
    # Prepare output / temp filename
    output_check(output_path)
    tmp_phar = ::Dir::Tmpname.create(['_\$fpm_phar_', o_stdext]) { }

    # Have PHP generate the package
    code = <<-PHP
       #-- Create phar
       $p = new Phar('#{tmp_phar}', 0, '#{name}');
       $p->startBuffering();

       #-- Add files
       $p->buildFromDirectory('#{staging_path}');
       
       #-- Stub
       if (strlen('#{o_stub}') && file_exists('#{staging_path}/#{o_stub}')) {
          $p->setStub(file_get_contents('#{staging_path}/#{o_stub}'));
       }
       elseif (#{o_format} == Phar::PHAR) {
          $p->setDefaultStub("__init__.php", "index.php");
       }
       else {
          $p->setDefaultStub();
       }

       #-- Carry packaging info over as meta data (in particular for `fpm -s src` module)
       $p->setMetadata(json_decode($_SERVER["argv"][1]));

       #-- Per-file compression
       if (#{o_filegz}) {
          $p->compressFiles(#{o_filegz});
       }
       
       #-- Signature
       if (strlen('#{o_sign}')) {
          $p->setSignatureAlgorithm(Phar::OPENSSL, file_get_contents('#{o_sign}'));
       }
       else {
          $p->setSignatureAlgorithm(Phar::SHA256);
       }
              
       #-- Save all the things
       $p->stopBuffering();

       // Whole-archive compression; output goes to a different filename. (Cleaned up in Ruby...)
       if ("#{o_extout}") {
          $p->compress(#{o_hullgz});
       }
    PHP
    safesystem("php", "-dphar.readonly=0", "-derror_reporing=~0", "-ddisplay_errors=1", "-r", code, JSON.generate(meta))

    #-- but might end up with suffix, for whole-archive ->compress()ion
    FileUtils.mv(tmp_phar + o_extout, output_path)
    File.unlink(tmp_phar) if File.exists?(tmp_phar)
  end

end # class FPM::Package::Phar
