# frozen_string_literal: true

source "https://rubygems.org"

gem "autoproj", git: "https://github.com/rock-core/autoproj"
group :vscode do
    gem "debase", ">= 0.2.2.beta10"
    gem "pry"
    gem "pry-byebug"
    gem "rubocop"
    gem "rubocop-rock"
    gem "ruby-debug-ide", ">= 0.6.0"
    gem "solargraph"
end

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in autoproj-ci.gemspec
gemspec
