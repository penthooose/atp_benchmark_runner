defmodule AtpBenchmarkRunner.TPTP.SingleDownloadTest do
  use ExUnit.Case, async: true

  alias AtpBenchmarkRunner.{Config, TPTP}
  alias AtpBenchmarkRunner.TPTP.Downloader

  @sample_html """
  <!DOCTYPE html>
  <html xmlns="http://www.w3.org/1999/xhtml" lang="en-US" xml:lang="en-US">
  <head><title>TPTP Problem File: GRP001-1.p</title></head>
  <body>
  <HR><CENTER>
  <H2>TPTP Problem File: GRP001-1.p</H2>
  </CENTER><HR>
  <pre>
  % File     : GRP001-1 : TPTP v9.3.0. Released v1.0.0.
  % Domain   : Group Theory
  % Status   : Unsatisfiable
  % Rating   : 0.00 v8.2.0
  % SPC      : CNF_UNS_RFO_SEQ_HRN
  % Comments : See <a href=SeeTPTP?Category=Documents&File=SomeDoc>SomeDoc</a>.

  %----Include group axioms
  include('Axioms/<a href=SeeTPTP?Category=Axioms&File=GRP003-0.ax>GRP003-0.ax</a>').
  <A NAME="square_element"></A>cnf(square_element,hypothesis,
      product(X,X,identity) ).
  </pre>
  <HR>
  </body>
  </html>
  """

  @sample_ax_html """
  <html><head><title>TPTP Axiom File: GRP003-0.ax</title></head>
  <body><pre>
  % File     : GRP003-0 : TPTP v9.3.0.
  % Domain   : Group Theory
  fof(left_identity,axiom,
      ( multiply(identity,X) = X ) ).
  </pre></body></html>
  """

  @not_found_html """
  <html><head><title>TPTP Problem File: GRP001-0.p</title></head>
  <body>
  <pre></pre>
  ERROR: Cannot read /home/tptp/TPTP-v9.3.0/Problems/GRP/GRP001-0.p No such file or directory
  </body></html>
  """

  describe "Config.single_download_dir/1" do
    test "honors the ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR env var" do
      tmp = tmp_root("cfg_env")
      System.put_env("ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR", Path.join(tmp, "custom"))

      try do
        assert Config.single_download_dir() == Path.expand(Path.join(tmp, "custom"))
      after
        System.delete_env("ATP_BENCHMARK_RUNNER_SINGLE_DOWNLOAD_DIR")
      end
    end
  end

  describe "Downloader.single_problem_url/1" do
    test "builds the SeeTPTP CGI URL with an inferred domain" do
      assert Downloader.single_problem_url("GRP001-1.p") ==
               "https://tptp.org/cgi-bin/SeeTPTP?Category=Problems&Domain=GRP&File=GRP001-1.p"
    end

    test "uses Category=Axioms for .ax files" do
      assert Downloader.single_problem_url("GRP003-0.ax") ==
               "https://tptp.org/cgi-bin/SeeTPTP?Category=Axioms&Domain=GRP&File=GRP003-0.ax"
    end

    test "omits the domain when the name has no three-letter TPTP prefix" do
      assert Downloader.single_problem_url("custom.p") ==
               "https://tptp.org/cgi-bin/SeeTPTP?Category=Problems&File=custom.p"
    end
  end

  describe "Downloader.extract_single_problem/2" do
    test "extracts the <pre> block, flattens anchors, and strips tags" do
      assert {:ok, content} = Downloader.extract_single_problem(@sample_html, "GRP001-1.p")

      assert content =~ "% File     : GRP001-1 : TPTP v9.3.0"
      assert content =~ "include('Axioms/GRP003-0.ax')."
      assert content =~ "cnf(square_element,hypothesis,"
      refute content =~ "<pre>"
      refute content =~ "<a href"
      refute content =~ "<A NAME="
      refute content =~ "</a>"
    end

    test "reports not-found when the server embeds the error marker" do
      assert {:error, {:not_found, "GRP001-0.p"}} =
               Downloader.extract_single_problem(@not_found_html, "GRP001-0.p")
    end

    test "reports not-found for an empty pre block" do
      html = "<html><body><pre>\n\n</pre></body></html>"
      assert {:error, {:not_found, "X.p"}} = Downloader.extract_single_problem(html, "X.p")
    end

    test "reports no_problem_block when no pre exists" do
      html = "<html><body><p>not a problem page</p></body></html>"
      assert {:error, {:no_problem_block, "X.p"}} = Downloader.extract_single_problem(html, "X.p")
    end
  end

  describe "TPTP.download_problems/2" do
    test "resolves bundled smoke names from the bundled tmp dir by default" do
      tmp = tmp_root("dl_fallback")
      # Simulate the official server not knowing these bundled smoke names.
      fetch_fun = fn _url -> {:ok, @not_found_html} end

      assert {:ok, problems, []} =
               TPTP.download_problems(["GRP001-0.p", "LAT001+0.p"],
                 root_dir: tmp,
                 fetch_fun: fetch_fun
               )

      assert Enum.map(problems, & &1.name) == ["GRP001-0", "LAT001+0"]

      # Resolved from the bundled examples (auto-populated from priv), NOT
      # copied into the archive-consistent Problems/ layout.
      assert Enum.all?(problems, fn p ->
               not String.starts_with?(p.path, Path.expand(Path.join(tmp, "Problems")))
             end)

      # The files are the actual bundled problem bodies.
      grp = Enum.find(problems, &(&1.name == "GRP001-0"))
      assert File.read!(grp.path) =~ "unit_a"

      refute File.exists?(Path.expand(Path.join(tmp, "Problems/GRP/GRP001-0.p")))
      refute File.exists?(Path.expand(Path.join(tmp, "Problems/LAT/LAT001+0.p")))
    end

    test "bundled_fallback: false is strict server-only (warn + skip, nothing written)" do
      tmp = tmp_root("dl_strict")
      fetch_fun = fn _url -> {:ok, @not_found_html} end

      assert {:ok, [], [%{name: "SMT001+0.p", reason: {:not_found, "SMT001+0.p"}}]} =
               TPTP.download_problems(["SMT001+0.p"],
                 root_dir: tmp,
                 bundled_fallback: false,
                 fetch_fun: fetch_fun
               )

      refute File.exists?(Path.expand(Path.join(tmp, "Problems/SMT/SMT001+0.p")))
    end
  end

  describe "name resolution integration" do
    test "resolve_problem_name finds files in the single-download cache dir" do
      tmp = tmp_root("dl_resolve")
      fetch_fun = fn _url -> {:ok, @sample_html} end

      assert {:ok, [problem], []} =
               TPTP.download_problems(["GRP001-1.p"], root_dir: tmp, fetch_fun: fetch_fun)

      assert TPTP.resolve_problem_name("GRP001-1.p", root_dir: tmp) == problem.path
    end
  end

  defp tmp_root(tag) do
    Path.join(System.tmp_dir!(), "atp_single_dl_#{tag}_#{System.unique_integer([:positive])}")
  end
end
