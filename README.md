# Autoproj::CI


## Installation

Run

~~~
autoproj plugin install autoproj-ci
~~~

From within an autoproj workspace

## Usage

### Build cache

The `autoproj ci cache-push` and `autoproj ci cache-pull` subcommands allow you
to save build artifacts (push) or get them from the cache (pull) to avoid
re-building things that are not needed. The pull must be done after a
successful bootstrap and checkout of the workspace. The push after a build.
`cache-push` will automatically ignore packages whose build have failed,
**from the last build**. So, make sure to run it after a complete build.

`cache-pull` generates a JSON file that can be used to determine what has been
pulled from the cache. Cached packages can then be provided to the `--not` option
of `autoproj build`, as e.g.

~~~
autoproj build --not this_package that_package
~~~

Passing the options must be done by your build environment. It's not automatically
handled by the tools

## Development

Install the plugin with a `--path` option to use your working checkout

~~~
autoproj plugin install autoproj-ci --path /path/to/checkout
~~~

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/rock-core/autoproj-ci. This project is intended to be a
safe, welcoming space for collaboration, and contributors are expected to
adhere to the [Contributor Covenant](http://contributor-covenant.org) code of
conduct.

## License

The gem is available as open source under the terms of the [MIT
License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Autoproj::Ci project’s codebases, issue trackers,
chat rooms and mailing lists is expected to follow the [code of
conduct](https://github.com/[USERNAME]/autoproj-ci/blob/master/CODE_OF_CONDUCT.md).
