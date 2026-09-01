# Lambda Package Action

This composite GitHub Action packages prepared Python or Node.js Lambda content
as either a deployment zip or a Lambda layer archive.

It intentionally does not install dependencies. Build dependencies with the
same Lambda runtime and architecture used in production, then pass the prepared
directory to this action. This keeps dependency resolution, package creation,
and deployment responsibilities separate.

## Archive layouts

| Mode | Python | Node.js |
| --- | --- | --- |
| `zip` | Application source and `site-packages` contents at archive root | Application source at archive root and dependencies under `node_modules/` |
| `layer` | Application/shared source and `site-packages` contents under `python/` | Prepared dependencies under `nodejs/node_modules/` |

For Node.js layer mode, install any shared application code as a package in
`node_modules`. Lambda resolves layer dependencies from that path.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `mode` | No | `zip` (default) or `layer`. |
| `runtime` | Yes | `python` or `node`. |
| `source_dir` | Zip mode | Workspace-relative application source directory. Optional for Python layer mode; unsupported for Node.js layer mode. |
| `dependencies_dir` | No for Python; yes for Node.js layer | Workspace-relative prepared Python `site-packages` directory or Node.js `node_modules` directory. |
| `output_path` | No | Workspace-relative archive path. Defaults to `lambda-package.zip`. |
| `exclude` | No | Newline-delimited archive-relative glob patterns to exclude. Patterns cannot begin with `-` or `@`. |

The action excludes source-control files, common Python caches, virtual
environments, `node_modules` found inside `source_dir`, and `.env` files by
default. Supply dependencies explicitly through `dependencies_dir`.

All input directories and output parents must be inside `GITHUB_WORKSPACE`.
The action rejects symbolic links in input, output, and staged content, so
archives cannot dereference links to runner files.

## Outputs

| Output | Description |
| --- | --- |
| `zip_path` | Absolute path to the generated archive. |
| `archive_sha256` | SHA-256 digest of the generated archive. |

## Python deployment zip

```yaml
- name: Build dependencies for Lambda
  run: |
    python -m pip install \
      --requirement requirements.txt \
      --target .build/site-packages

- name: Package Lambda
  id: package
  uses: <owner>/lambda-package-action@<immutable-commit-sha>
  with:
    mode: zip
    runtime: python
    source_dir: src
    dependencies_dir: .build/site-packages
    output_path: dist/function.zip
```

## Python Lambda layer

Build dependencies in a Linux environment compatible with the target Lambda
architecture. For an x86_64 Python 3.11 layer:

```yaml
- name: Build layer dependencies
  run: |
    mkdir -p .build/site-packages
    docker run --rm --platform linux/amd64 \
      --volume "$PWD/.build/site-packages:/var/task/python" \
      --volume "$PWD/requirements.txt:/var/task/requirements.txt:ro" \
      public.ecr.aws/lambda/python:3.11 \
      python -m pip install --no-cache-dir \
        --requirement /var/task/requirements.txt \
        --target /var/task/python

- name: Package Lambda layer
  id: package
  uses: <owner>/lambda-package-action@<immutable-commit-sha>
  with:
    mode: layer
    runtime: python
    source_dir: shared
    dependencies_dir: .build/site-packages
    output_path: dist/common-layer.zip
```

This produces:

```text
python/
  <shared Python modules>
  <installed dependencies>
```

## Node.js deployment zip and layer

```yaml
- name: Install production dependencies
  run: npm ci --omit=dev

- name: Package deployment zip
  uses: <owner>/lambda-package-action@<immutable-commit-sha>
  with:
    mode: zip
    runtime: node
    source_dir: src
    dependencies_dir: node_modules
    output_path: dist/function.zip

- name: Package Lambda layer
  uses: <owner>/lambda-package-action@<immutable-commit-sha>
  with:
    mode: layer
    runtime: node
    dependencies_dir: node_modules
    output_path: dist/node-layer.zip
```

## Requirements

Use a Linux runner with Bash, `zip`, `unzip`, and `sha256sum`. GitHub-hosted
Ubuntu runners include these tools.

## Security model

This action packages only prepared files. It does not download dependencies,
run package-manager lifecycle scripts, or accept arbitrary commands.

Use workspace-relative paths from trusted workflow configuration. Do not bind
inputs to untrusted pull-request data or workflow-dispatch text without
validation. The action runs in the consumer job and therefore shares that
job's workspace, environment, and credentials.

Protect the action repository's `main` branch and version tags. Restrict who
can modify workflows or run releases. Consumers should pin this action to an
immutable commit SHA rather than a mutable tag.

## CI and releases

`CI` tests Python and Node.js deployment zip and layer layouts on pull requests
and pushes to `main`. The manual `Release` workflow creates a semantic-version
tag such as `v1.0.0` and refuses to overwrite an existing tag. Configure GitHub
tag protection if version tags must be immutable.

Pin production consumers to an immutable commit SHA. A version tag is useful
for discovery, but a commit SHA prevents a moved tag from changing a deployed
workflow unexpectedly.
