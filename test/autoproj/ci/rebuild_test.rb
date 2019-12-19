# frozen_string_literal: true

require 'test_helper'
require 'rubygems/package'
require 'autoproj/ci/rebuild'

module Autoproj::CI # rubocop:disable Style/ClassAndModuleChildren, Style/Documentation
    module Rebuild
        describe '.prepare_synthetic_buildroot' do
            before do
                @out = make_tmpdir
                @cache_dir = fixture_path('cache')
            end

            it 'builds the synthetic buildfile' do
                create_and_unpack
                assert File.file?(File.join(@out, 'path', 'to', 'base', 'types',
                                            'prefix', 'base-types'))
                assert File.file?(File.join(@out, 'path', 'to', 'drivers',
                                            'iodrivers_base', 'prefix',
                                            'drivers-iodrivers_base'))
            end

            it 'ignores package sets' do
                create_and_unpack(versions: 'versions_with_pkg_set.yml')
                assert File.file?(File.join(@out, 'path', 'to', 'base', 'types',
                                            'prefix', 'base-types'))
                assert File.file?(File.join(@out, 'path', 'to', 'drivers',
                                            'iodrivers_base', 'prefix',
                                            'drivers-iodrivers_base'))
            end

            it 'fails if the cache file does not exist' do
                e = assert_raises(RuntimeError) do
                    create_and_unpack(
                        versions: 'versions_with_nonexistent_fingerprint.yml'
                    )
                end
                assert_equal 'no cache file found for fingerprint \'some-nonexistent-'\
                             "fingerprint\', package \'base/types\' in #{@cache_dir}",
                             e.message
            end

            it 'fails if the cache has no directory for the package' do
                e = assert_raises(RuntimeError) do
                    create_and_unpack(
                        versions: 'versions_with_package_without_cache.yml'
                    )
                end
                assert_equal 'no cache file found for fingerprint \'some-fingerprint\', '\
                             "package \'non/existent/package\' in #{@cache_dir}",
                             e.message
            end

            it 'fails if the cache file fails at unpacking' do
                e = assert_raises(RuntimeError) do
                    create_and_unpack(
                        versions: 'versions_with_invalid_cache_file.yml'
                    )
                end
                assert_match %r{failed to unpack .*invalid/cache/fingerprint in},
                             e.message
            end

            def fixture_path(*name)
                File.realpath(File.join(__dir__, 'fixtures', 'rebuild', *name))
            end

            def create_and_unpack(
                manifest: 'installation-manifest',
                versions: 'versions.yml',
                cache: 'cache'
            )
                Rebuild.prepare_synthetic_buildroot(
                    fixture_path(manifest),
                    fixture_path(versions),
                    fixture_path(cache),
                    @out
                )
            end
        end
    end
end
