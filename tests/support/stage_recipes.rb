# frozen_string_literal: true

# Sub-pipeline recipes for unit tests. The public surface has exactly two
# presets (:stable / :unstable); tests additionally pin the behavior of
# individual stages by composing steps directly — the supported way to run
# a partial pipeline. The historical numbers survive here only as recipe
# names, so stage-focused tests can keep saying which slice they exercise.
#
# Lives outside test_helper so suites that skip coverage tracking (the gem
# canaries) can share the recipes without pulling SimpleCov in.
module MinifyTestHelper
  STAGE_RECIPES = {
    0 => [],
    1 => [*Ryac::Minifier::OPTIMIZE_PRE, *Ryac::Minifier::OPTIMIZE_POST],
    2 => [*Ryac::Minifier::OPTIMIZE_PRE,
          [Ryac::Pipeline::ConstantAliaser], [Ryac::Pipeline::AttrDeclShorten],
          *Ryac::Minifier::OPTIMIZE_POST],
    3 => [*Ryac::Minifier::OPTIMIZE_PRE,
          [Ryac::Pipeline::ConstantAliaser], [Ryac::Pipeline::AttrDeclShorten],
          [Ryac::Pipeline::VariableRenamer, { features: { keywords: true } }],
          *Ryac::Minifier::OPTIMIZE_POST],
    4 => Ryac::Minifier::STAGES[:stable],
    5 => Ryac::Minifier::STAGES[:unstable]
  }.freeze
end
