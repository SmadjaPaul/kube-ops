# BookOrbit Project Gutenberg mirror integration

The BookOrbit v3.9.0 plugin at `k8s/applications/media/bookorbit/plugins/gutenberg-fr-candide.mjs` uses the official generated-content mirror `gutenberg.pglaf.org`. It never calls `www.gutenberg.org` and only returns the verified French EPUB for Candide by Voltaire (Project Gutenberg ebook 59859).

The plugin is mounted read-only from a GitOps ConfigMap under BookOrbit's plugin directory. The matching Cilium policy allows HTTPS to the mirror hostname. A pod restart reloads the exact reviewed plugin file from Git, while BookOrbit's plugin source configuration remains in its persistent app settings.

This integration intentionally exposes one title. Project Gutenberg cautions that readers outside the United States must check local copyright status. Voltaire died in 1778, so this curated work is public domain in France. The plugin does not infer rights status for the broader catalog or enable unrestricted Gutenberg searching.

Project Gutenberg's [robot access policy](https://www.gutenberg.org/policy/robot_access.html) directs automated users to mirrors, and its [mirroring guide](https://www.gutenberg.org/help/mirroring.html) documents the generated EPUB collection and official `gutenberg.pglaf.org` rsync mirror. Its [terms](https://www.gutenberg.org/policy/terms_of_use.html) place local copyright checks on users outside the United States.

The offline check runs `tests/harness/bookorbit-gutenberg-fr-candide.test.mjs`. The source's connection test also verifies the mirrored RDF metadata and EPUB before it reports a healthy connection.
