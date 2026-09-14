# Project databases on the shared server

One file per project, **generated** by `scripts/new-project-db.sh` — role,
database and the sealed role password for every environment. Do not hand-edit
the sealed values; re-run the script (`--force` rotates).

This README also keeps the directory tracked. Git does not store empty
directories, and the `postgres-databases` Application points `path:` here: with
no tracked file, a fresh clone has no directory and ArgoCD reports
`app path does not exist` until the first project database is generated.
ArgoCD's directory source only reads `.yaml`/`.yml`/`.json`, so this file is
ignored by the sync itself.

See [docs/onboarding.md](../../../../docs/onboarding.md) "Add a database".
