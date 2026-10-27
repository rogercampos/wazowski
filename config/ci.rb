# Verification steps for the whole repo. Run them with `bin/ci`.

CI.run "Wazowski CI", "Tests" do
  step "Tests", "bundle", "exec", "rake", "test"

  if success?
    step "Signoff: All systems go. Ready for merge.", "echo", "The gem is in good shape."
  else
    failure "Signoff: Failed. Do not merge.", "Fix the issues above and run bin/ci again."
  end
end
