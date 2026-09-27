# homebrew-tap

This directory holds the formula published as the `ompurwar/tap` tap.

## Publishing a new version

1. Tag the repo: `git tag v0.1.0 && git push origin v0.1.0`
2. Update the `url` and `version` in `voxtype.rb` to match the tag.
3. Copy the formula into the tap repo and commit:

   ```bash
   cp voxtype.rb /path/to/homebrew-tap/Formula/voxtype.rb
   cd /path/to/homebrew-tap
   git add Formula/voxtype.rb
   git commit -m "voxtype 0.1.0"
   git push
   ```

4. Verify: `brew update && brew install ompurwar/tap/voxtype`

The formula tarball must point at an existing git tag, so the tag has to be
pushed before the formula is committed to the tap.
