defmodule AtpBenchmarkRunner.LivebookSetupTest do
  use ExUnit.Case, async: false

  alias AtpBenchmarkRunner.LivebookSetup

  describe "inputs/0" do
    test "covers the key env vars the runner reads" do
      env_keys = LivebookSetup.inputs() |> Enum.map(& &1.env)

      assert "TPTP_ROOT" in env_keys
      assert "ATP_BENCHMARK_RUNNER_STORE_DIR" in env_keys
      assert "ATP_BENCHMARK_RUNNER_SMT_TMP_DIR" in env_keys
      assert "HPC_CONNECT_CLUSTER" in env_keys
      assert "HPC_CONNECT_USERNAME" in env_keys
      assert "HPC_CONNECT_RETRY_FOREVER" in env_keys
      assert "ATP_BENCHMARK_RUNNER_HPC_MODE" in env_keys
      assert "ATP_BENCHMARK_RUNNER_HPC_PARTITION" in env_keys
    end

    test "marks HUGGINGFACE_HUB_TOKEN as a secret (never persisted)" do
      hf = Enum.find(LivebookSetup.inputs(), &(&1.env == "HUGGINGFACE_HUB_TOKEN"))
      assert hf.type == :secret
    end
  end

  describe "resolve_defaults/4" do
    test "persisted value wins over env file value" do
      persisted = %{"TPTP_ROOT" => "/persisted/tptp"}
      env_map = %{"TPTP_ROOT" => "/env/tptp"}

      defaults =
        LivebookSetup.resolve_defaults(LivebookSetup.inputs(), persisted, env_map, "/tmp")

      assert defaults["TPTP_ROOT"] == "/persisted/tptp"
    end

    test "env file value fills when persisted is blank" do
      defaults =
        LivebookSetup.resolve_defaults(
          LivebookSetup.inputs(),
          %{},
          %{"TPTP_ROOT" => "/env/tptp"},
          "/tmp"
        )

      assert defaults["TPTP_ROOT"] == "/env/tptp"
    end

    test "path fields default to the session temp base when unconfigured" do
      defaults = LivebookSetup.resolve_defaults(LivebookSetup.inputs(), %{}, %{}, "/sess/tmp")

      assert defaults["TPTP_ROOT"] == "/sess/tmp/tptp"
      assert defaults["ATP_BENCHMARK_RUNNER_STORE_DIR"] == "/sess/tmp/store"
      assert defaults["ATP_BENCHMARK_RUNNER_SMT_TMP_DIR"] == "/sess/tmp/smt_converted"
    end

    test "non-path fields fall back to their static default" do
      defaults = LivebookSetup.resolve_defaults(LivebookSetup.inputs(), %{}, %{}, "/tmp")

      assert defaults["HPC_CONNECT_CLUSTER"] == "helma"
      assert defaults["HPC_CONNECT_RETRY_FOREVER"] == "true"
      assert defaults["ATP_BENCHMARK_RUNNER_HPC_PARTITION"] == "cpu"
    end
  end

  describe "non_blank/1 and render_env_content/1" do
    test "select options are converted to {value, label} tuples (Kino ≥ 0.19)" do
      assert LivebookSetup.select_options(["helma", "fritz"]) ==
               [{"helma", "helma"}, {"fritz", "fritz"}]
    end

    test "filters nil and blank values" do
      assert LivebookSetup.non_blank(%{"A" => "x", "B" => "", "C" => nil, "D" => "  "}) == %{
               "A" => "x"
             }
    end

    test "renders sorted KEY=VALUE lines" do
      content =
        LivebookSetup.render_env_content(%{
          "HPC_CONNECT_CLUSTER" => "helma",
          "TPTP_ROOT" => "/tmp/tptp"
        })

      assert content == "HPC_CONNECT_CLUSTER=helma\nTPTP_ROOT=/tmp/tptp"
    end

    test "quotes values containing whitespace or hashes" do
      content = LivebookSetup.render_env_content(%{"TPTP_ROOT" => "C:/My Folder/tptp #x"})
      assert content == "TPTP_ROOT=\"C:/My Folder/tptp #x\""
    end

    test "write_env_file returns a normalized (Path.expand'd) path" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "atp_livebook_setup_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      raw = Path.join(tmp, "x.env")
      path = LivebookSetup.write_env_file(%{"A" => "1"}, env_output_path: raw)

      assert path == Path.expand(raw)
      assert File.exists?(path)
      assert File.read!(path) =~ "A=1"
    end
  end

  describe "prepare/1 in :local mode" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "atp_livebook_setup_test_#{System.unique_integer([:positive])}"
        )

      env_file = Path.join(tmp, "input.env")
      File.mkdir_p!(tmp)
      File.write!(env_file, "TPTP_ROOT=/from/file/tptp\nHPC_CONNECT_CLUSTER=fritz\n")

      env_keys = LivebookSetup.inputs() |> Enum.map(& &1.env)
      before_env = Map.new(env_keys, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(before_env, fn {k, v} ->
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end)

        File.rm_rf!(tmp)
      end)

      %{tmp: tmp, env_file: env_file}
    end

    test "applies env and writes a temp env file for bootstrap", %{tmp: tmp, env_file: env_file} do
      result =
        LivebookSetup.prepare(
          mode: :local,
          env_file: env_file,
          persist_path: Path.join(tmp, "setup.json"),
          env_output_path: Path.join(tmp, "out.env"),
          tmp_base: Path.join(tmp, "sess")
        )

      assert result.env_map["TPTP_ROOT"] == "/from/file/tptp"
      assert result.env_map["HPC_CONNECT_CLUSTER"] == "fritz"
      assert result.persisted_path == Path.join(tmp, "setup.json")

      # The returned env_file is the written temp .env used by bootstrap.
      assert File.exists?(result.env_file)
      assert File.read!(result.env_file) =~ "TPTP_ROOT=/from/file/tptp"
      assert File.read!(result.env_file) =~ "HPC_CONNECT_CLUSTER=fritz"

      # Applied to the OS env too, so Config.get picks it up.
      assert System.get_env("TPTP_ROOT") == "/from/file/tptp"
    end

    test "path defaults land in the session temp base when unconfigured", %{tmp: tmp} do
      result =
        LivebookSetup.prepare(
          mode: :local,
          env_file: nil,
          persist_path: Path.join(tmp, "setup.json"),
          env_output_path: Path.join(tmp, "out.env"),
          tmp_base: Path.join(tmp, "sess")
        )

      assert result.env_map["TPTP_ROOT"] == Path.join(tmp, "sess/tptp")
      assert result.env_map["ATP_BENCHMARK_RUNNER_STORE_DIR"] == Path.join(tmp, "sess/store")
    end

    test "persisted values are reused and secrets are not persisted", %{tmp: tmp} do
      persist_path = Path.join(tmp, "setup.json")
      env_file = Path.join(tmp, "input.env")

      # First run: env provides a value; HUGGINGFACE_HUB_TOKEN is filled in the form values.
      result1 =
        LivebookSetup.prepare(
          mode: :local,
          env_file: env_file,
          persist_path: persist_path,
          env_output_path: Path.join(tmp, "out1.env"),
          tmp_base: Path.join(tmp, "sess1")
        )

      assert result1.env_map["HPC_CONNECT_CLUSTER"] == "fritz"

      # Simulate the persisted file keeping the form values (secret stripped).
      persisted = LivebookSetup.non_blank(result1.values) |> Map.drop(["HUGGINGFACE_HUB_TOKEN"])
      File.write!(persist_path, Jason.encode!(persisted))

      # Second run with a DIFFERENT env file: stored value wins over env.
      other_env = Path.join(tmp, "other.env")
      File.write!(other_env, "HPC_CONNECT_CLUSTER=woody\n")

      result2 =
        LivebookSetup.prepare(
          mode: :local,
          env_file: other_env,
          persist_path: persist_path,
          env_output_path: Path.join(tmp, "out2.env"),
          tmp_base: Path.join(tmp, "sess2")
        )

      assert result2.env_map["HPC_CONNECT_CLUSTER"] == "fritz"
      refute Jason.decode!(File.read!(persist_path)) |> Map.has_key?("HF_TOKEN")
    end

    test "exposes the effective SSH key in the result map", %{tmp: tmp} do
      result =
        LivebookSetup.prepare(
          mode: :local,
          env_file: nil,
          persist_path: Path.join(tmp, "setup.json"),
          env_output_path: Path.join(tmp, "out.env"),
          tmp_base: Path.join(tmp, "sess")
        )

      assert Map.has_key?(result, :ssh_key_path)
      assert Map.has_key?(result, :ssh_key_temporary?)
      # No upload in :local mode, so the key is never a temp staged copy.
      assert result.ssh_key_temporary? == false
    end

    test "keeps a persisted SSH identity (auto-detect never clobbers it)", %{tmp: tmp} do
      persist_path = Path.join(tmp, "setup.json")
      File.write!(persist_path, Jason.encode!(%{"HPC_CONNECT_IDENTITY_FILE" => "~/.ssh/id_test"}))

      result =
        LivebookSetup.prepare(
          mode: :local,
          env_file: nil,
          persist_path: persist_path,
          env_output_path: Path.join(tmp, "out.env"),
          tmp_base: Path.join(tmp, "sess")
        )

      assert result.values["HPC_CONNECT_IDENTITY_FILE"] == "~/.ssh/id_test"
    end
  end

  describe "cleanup/1" do
    test "prints a friendly notice when no temp key is recorded" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "atp_livebook_setup_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert LivebookSetup.cleanup(registry_path: Path.join(tmp, "none.json")) == :ok
        end)

      assert output =~ "No temporary SSH key found"
    end
  end
end
