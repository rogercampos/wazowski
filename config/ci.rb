# Verification steps for the whole repo. Run them with `bin/ci`.
#
# The gemspec caps Active Record at the newest minor these steps run on (see
# Wazowski::ActiveRecordAdapter.before_commit_hook). To support a new Rails,
# add its gemfile here and raise the cap once this passes.

CI.run "Wazowski CI", "Tests" do
  step "Tests: Rails 8.1", "bundle", "exec", "rake", "test"
  # Without the environment bin/ci's own bundler/setup exports (BUNDLE_LOCKFILE
  # among it), which would resolve Rails 8.0 into the root Gemfile.lock.
  Bundler.with_unbundled_env do
    step "Tests: Rails 8.0", "env", "BUNDLE_GEMFILE=gemfiles/8.0.gemfile", "bundle", "exec", "rake", "test"
  end

  if success?
    step "Signoff: All systems go. Ready for merge.", "echo", "The gem is in good shape."
  else
    failure "Signoff: Failed. Do not merge.", "Fix the issues above and run bin/ci again."
  end
end
