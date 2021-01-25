# frozen_string_literal: true

require "autoproj"
require "tmpdir"

module Autoproj
    module CI
        # Utilities to re-create a system image from the results of a CI build
        module Rebuild
            # Create a single tarball containing all the artifacts of a given build
            #
            # The generated tarball is 'rooted' at the filesystem root, i.e. it is meant
            # to be unpacked from /
            def self.prepare_synthetic_buildroot(
                installation_manifest_path, versions_path, cache_root_path, output_dir
            )
                manifest = Autoproj::InstallationManifest.new(installation_manifest_path)
                manifest.load
                versions = YAML.safe_load(File.read(versions_path))

                versions.each do |entry|
                    name, entry = entry.first
                    next if /^pkg_set:/.match?(name)

                    unpack_package(
                        output_dir,
                        cache_root_path, name,
                        manifest.packages.fetch(name),
                        entry.fetch("fingerprint")
                    )
                end
            end

            def self.dpkg_create_package_install(status_path, rules, orig: nil)
                installed, = Autoproj::PackageManagers::AptDpkgManager
                             .parse_dpkg_status(status_path, virtual: false)

                if orig
                    orig_installed, = Autoproj::PackageManagers::AptDpkgManager
                                      .parse_dpkg_status(orig, virtual: false)
                    installed -= orig_installed
                end

                installed.find_all do |pkg_name|
                    package_matches_rules?(pkg_name, rules)
                end
            end

            def self.package_matches_rules?(pkg_name, rules)
                rules.each do |mode, r|
                    return mode if r.match?(pkg_name)
                end
                true
            end

            # Unpack a single package in its place within the
            def self.unpack_package(output_path, cache_root_path, name, pkg, fingerprint)
                cache_file_path = File.join(cache_root_path, name, fingerprint)
                unless File.file?(cache_file_path)
                    raise "no cache file found for fingerprint '#{fingerprint}', "\
                          "package '#{name}' in #{cache_root_path}"
                end

                package_prefix = File.join(output_path, pkg.prefix)
                FileUtils.mkdir_p(package_prefix)
                unless system("tar", "xzf", cache_file_path,
                              chdir: package_prefix, out: "/dev/null")
                    raise "failed to unpack #{cache_file_path} in #{package_prefix} "\
                          "for package #{name} failed"
                end
            end
        end
    end
end
