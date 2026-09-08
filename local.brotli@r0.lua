-- @envy schema "1"
--
-- Static brotli: headers plus libbrotli{enc,dec,common}.a, for linking into conductor-qol.
--
-- Static is the entire point. Conductor's frontend is brotli-compressed inside its
-- Mach-O, so the patcher needs both codecs, and macOS ships neither -- brotli is absent
-- from /usr/lib and from the SDK, and Compression.framework covers only LZFSE/LZ4/LZMA/
-- zlib. Linking the archives keeps the shipped binary dependent on nothing but
-- libSystem, Foundation and the OS Swift runtime.
--
-- BUILD_SHARED_LIBS=OFF is what makes that work: brotli's plain `add_library()` targets
-- become STATIC and its install() rules follow them to `lib/*.a` (upstream
-- CMakeLists.txt defaults the option to ON).

IDENTITY = "local.brotli@r0"
EXPORTABLE = true
PLATFORMS = { "darwin" }

-- macos_deployment_target has to match the -target swiftc is given, or every object in
-- the archives draws a "built for newer macOS version than being linked" warning.
OPTIONS = {
  version = { required = true },
  macos_deployment_target = { required = false },
}

DEPENDENCIES = {
  {
    spec = "envy.cmake@r1",
    bundle = {
      identity = "envy.package-specs@r5",
      -- https + `.git` suffix, which envy classifies as GIT_HTTPS. The `git://` form the
      -- package-specs README shows cannot work: GitHub retired the git protocol in 2022,
      -- and libgit2 just times out on port 9418.
      source = "https://github.com/envy-package-manager/package-specs.git",
      ref = "bcefe9c790009f4aa6b12dd94e37c60204489a4c",
    },
    options = { version = "4.4.3" },
  },
}

local sha256_fingerprints = {
  ["1.2.0"] = "816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec",
}

FETCH = function(tmp_dir, opts)
  local fingerprint = sha256_fingerprints[opts.version]
  assert(fingerprint, "unsupported brotli version: " .. opts.version)

  return {
    source = "https://github.com/google/brotli/archive/refs/tags/v" ..
        opts.version .. ".tar.gz",
    sha256 = fingerprint,
  }
end

STAGE = { strip = 1 }

BUILD = function(install_dir, stage_dir, fetch_dir, tmp_dir, opts)
  return envy.template([[
"{{cmake}}" -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON -DCMAKE_OSX_DEPLOYMENT_TARGET={{deployment_target}} -DCMAKE_INSTALL_PREFIX="{{prefix}}"
"{{cmake}}" --build build --parallel
]], {
    cmake = envy.product("cmake"),
    prefix = install_dir,
    deployment_target = opts.macos_deployment_target or "13.0",
  })
end

INSTALL = function(install_dir, stage_dir, fetch_dir, tmp_dir, opts)
  return envy.template([["{{cmake}}" --install build]], { cmake = envy.product("cmake") })
end

-- Directory products, not scripts: these go on `-I` and `-L` lines, they are not
-- executables to deploy into the project bin directory.
PRODUCTS = {
  brotli_include_dir = { value = "include", script = false },
  brotli_lib_dir = { value = "lib", script = false },
}
