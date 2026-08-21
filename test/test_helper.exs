{:ok, _} = Application.ensure_all_started(:ash_feature_flags)

ExUnit.start()
