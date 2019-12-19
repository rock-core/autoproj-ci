# frozen_string_literal: true
require 'test_helper'
require 'thor'
require 'autoproj/cli/main_ci'

module Autoproj::CLI # rubocop:disable Style/ClassAndModuleChildren, Style/Documentation
    describe StandaloneCI do
        describe 'rebuild_root' do
            it 'builds a tarball from the build info' do
                config_root = File.join(__dir__, '..', 'ci', 'fixtures', 'rebuild')
                cache_root = File.join(config_root, 'cache')
                output = File.join(make_tmpdir, 'output.tar.gz')

                StandaloneCI.start(['rebuild-root', config_root, cache_root, output])

                out = make_tmpdir
                system('tar', 'xzf', output, chdir: out, out: '/dev/null')
                base_types_file = File.join(
                    out, 'path', 'to', 'base', 'types', 'prefix', 'base-types'
                )
                assert File.file?(base_types_file)
                iodrivers_base_file = File.join(
                    out, 'path', 'to', 'drivers', 'iodrivers_base',
                    'prefix', 'drivers-iodrivers_base'
                )
                assert File.file?(iodrivers_base_file)
            end
        end
    end
end

