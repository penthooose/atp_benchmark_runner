# ATP prover Apptainer definitions

This directory is owned by `atp_benchmark_runner` and contains one prover image
definition per supported theorem prover:

- `vampire/apptainer.def`
- `eprover/apptainer.def`
- `cvc5/apptainer.def`
- `zipperposition/apptainer.def`
- `leo3/apptainer.def`
- `leo2/apptainer.def`
- `tableaux/apptainer.def`
- `lash/apptainer.def`

## Integration with `hpc_connect`

Do **not** copy these files into the `hpc_connect` dependency's `priv/` tree.
Dependencies are build artifacts and may be fetched, rebuilt, or replaced. The
stable integration point is the public `hpc_connect` API:

1. `AtpBenchmarkRunner.HPC.Images.install_build_tools!/2` uploads the generic
   `hpc_connect` scripts, including `build_sif.sh`.
2. `AtpBenchmarkRunner.HPC.Images.upload_definitions!/3` uploads these local
   definitions to `<work_dir>/singularity_def_files/<name>.def` via
   `HpcConnect.upload_def_file/3`.
3. `AtpBenchmarkRunner.HPC.Images.build_all!/3` delegates builds to
   `HpcConnect.build_sif/3`, producing `.sif` images under
   `<work_dir>/singularity_images/<name>.sif`.

This keeps `hpc_connect` generic and reusable while allowing the benchmark runner
to own ATP-specific reproducibility details.

## Build notes

- FAU HPC runtime should use Apptainer `.sif` images.
- The default `hpc_connect` build path routes through its build-capable fallback
  clusters unless `build_cluster:` is explicitly provided.
- Some upstream prover projects publish release assets with non-uniform names;
  pin URLs here once a nightly benchmark image is verified.
- `lash` and `tableaux` are scaffold definitions until their stable source/CLI
  packaging is fixed.
