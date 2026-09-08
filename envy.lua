-- envy.lua - Project manifest
--
-- Toolchain for conductor-qol, the Conductor QoL patcher. macOS only: the tool is
-- Swift, patches a Mach-O, and drives codesign, so there is nothing to build elsewhere.
--
-- The cache is project-local by default (`cache-local` below) so a checkout leaves no
-- trace outside its own directory. Override with `bin/envy cache --shared`,
-- ENVY_CACHE_ROOT, or --cache-root.
--
-- @envy schema "1"
-- @envy version "0.3.1"
-- @envy bin "bin"
-- @envy sha256sums "4fa39d4f925351cb0582ca026a9ae1da5496e1671b7f231655c6875a0e097e3d"
-- @envy deploy "true"
-- @envy root "true"
-- @envy cache-local ".envy"

PACKAGES = {
  -- brotli pulls cmake in through its own DEPENDENCIES; it is the only thing the
  -- Swift build needs that the macOS SDK does not already ship.
  {
    spec = "local.brotli@r0",
    source = "local.brotli@r0.lua",
    -- macos_deployment_target must match the -target in build.sh.
    options = { version = "1.2.0", macos_deployment_target = "13.0" },
    platforms = { "darwin" },
  },
}
