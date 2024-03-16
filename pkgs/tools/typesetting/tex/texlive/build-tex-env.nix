{
  # texlive package set
  tl
, bin

, lib
, buildEnv
, libfaketime
, makeFontsConf
, makeWrapper
, runCommand
, writeShellScript
, writeText
, toTLPkgSets
, bash
, perl

  # common runtime dependencies
, coreutils
, gawk
, gnugrep
, gnused
, ghostscript
}:

lib.fix (self: {
  withDocs ? false
, withSources ? false
, requiredTeXPackages ? ps: [ ps.scheme-infraonly ]

### texlive.combine backward compatibility
, __extraName ? "combined"
, __extraVersion ? ""
# emulate the old texlive.combine (e.g. add man pages to main output)
, __combine ? false
# adjust behavior further if called from the texlive.combine wrapper
, __fromCombineWrapper ? false
}@args:

let
  ### texlive.combine backward compatibility
  # if necessary, convert old style { pkgs = [ ... ]; } packages to attribute sets
  isOldPkgList = p: ! p.outputSpecified or false && p ? pkgs && builtins.all (p: p ? tlType) p.pkgs;
  ensurePkgSets = ps: if ! __fromCombineWrapper && builtins.any isOldPkgList ps
    then let oldPkgLists = builtins.partition isOldPkgList ps;
      in oldPkgLists.wrong ++ lib.concatMap toTLPkgSets oldPkgLists.right
    else ps;

  pkgList = rec {
    # resolve dependencies of the packages that affect the runtime
    all =
      let
        # order of packages is irrelevant
        packages = builtins.sort (a: b: a.pname < b.pname) (ensurePkgSets (requiredTeXPackages tl));
        runtime = builtins.partition
          (p: p.outputSpecified or false -> builtins.elem (p.tlOutputName or p.outputName) [ "out" "tex" "tlpkg" ])
          packages;
        keySet = p: {
          key = ((p.name or "${p.pname}-${p.version}") + "-" + p.tlOutputName or p.outputName or "");
          inherit p;
          tlDeps = if p ? tlDeps then ensurePkgSets p.tlDeps else (p.requiredTeXPackages or (_: [ ]) tl);
        };
      in
      # texlive.combine: the wrapper already resolves all dependencies
      if __fromCombineWrapper then requiredTeXPackages null else
        builtins.catAttrs "p" (builtins.genericClosure {
          startSet = map keySet runtime.right;
          operator = p: map keySet p.tlDeps;
        }) ++ runtime.wrong;

    # group the specified outputs
    specified = builtins.partition (p: p.outputSpecified or false) all;
    specifiedOutputs = lib.groupBy (p: p.tlOutputName or p.outputName) specified.right;
    otherOutputNames = builtins.catAttrs "key" (builtins.genericClosure {
      startSet = map (key: { inherit key; }) (lib.concatLists (builtins.catAttrs "outputs" specified.wrong));
      operator = _: [ ];
    });
    otherOutputs = lib.genAttrs otherOutputNames (n: builtins.catAttrs n specified.wrong);
    outputsToInstall = builtins.catAttrs "key" (builtins.genericClosure {
      startSet = map (key: { inherit key; })
        ([ "out" ] ++ lib.optional (splitOutputs ? man) "man"
          ++ lib.concatLists (builtins.catAttrs "outputsToInstall" (builtins.catAttrs "meta" specified.wrong)));
      operator = _: [ ];
    });

    # split binary and tlpkg from tex, texdoc, texsource
    bin = if __fromCombineWrapper
      then builtins.filter (p: p.tlType == "bin") all # texlive.combine: legacy filter
      else otherOutputs.out or [ ] ++ specifiedOutputs.out or [ ];
    tlpkg = if __fromCombineWrapper
      then builtins.filter (p: p.tlType == "tlpkg") all # texlive.combine: legacy filter
      else otherOutputs.tlpkg or [ ] ++ specifiedOutputs.tlpkg or [ ];

    nonbin = if __fromCombineWrapper then builtins.filter (p: p.tlType != "bin" && p.tlType != "tlpkg") all # texlive.combine: legacy filter
      else (if __combine then # texlive.combine: emulate old input ordering to avoid rebuilds
        lib.concatMap (p: lib.optional (p ? tex) p.tex
          ++ lib.optional ((withDocs || p ? man) && p ? texdoc) p.texdoc
          ++ lib.optional (withSources && p ? texsource) p.texsource) specified.wrong
        else otherOutputs.tex or [ ]
          ++ lib.optionals withDocs (otherOutputs.texdoc or [ ])
          ++ lib.optionals withSources (otherOutputs.texsource or [ ]))
        ++ specifiedOutputs.tex or [ ] ++ specifiedOutputs.texdoc or [ ] ++ specifiedOutputs.texsource or [ ];

    # outputs that do not become part of the environment
    nonEnvOutputs = lib.subtractLists [ "out" "tex" "texdoc" "texsource" "tlpkg" ] otherOutputNames;
  };

  # list generated by inspecting `grep -IR '\([^a-zA-Z]\|^\)gs\( \|$\|"\)' "$TEXMFDIST"/scripts`
  # and `grep -IR rungs "$TEXMFDIST"`
  # and ignoring luatex, perl, and shell scripts (those must be patched using postFixup)
  needsGhostscript = lib.any (p: lib.elem p.pname [ "context" "dvipdfmx" "latex-papersize" "lyluatex" ]) pkgList.bin;

  name = if __combine then "texlive-${__extraName}-${bin.texliveYear}${__extraVersion}" # texlive.combine: old name name
    else "texlive-${bin.texliveYear}-env";

  texmfdist = (buildEnv {
    name = "${name}-texmfdist";

    # remove fake derivations (without 'outPath') to avoid undesired build dependencies
    paths = builtins.catAttrs "outPath" pkgList.nonbin;

    # mktexlsr
    nativeBuildInputs = [ tl."texlive.infra" ];

    postBuild = # generate ls-R database
    ''
      mktexlsr "$out"
    '';
  }).overrideAttrs (_: { allowSubstitutes = true; });

  tlpkg = (buildEnv {
    name = "${name}-tlpkg";

    # remove fake derivations (without 'outPath') to avoid undesired build dependencies
    paths = builtins.catAttrs "outPath" pkgList.tlpkg;
  }).overrideAttrs (_: { allowSubstitutes = true; });

  # the 'non-relocated' packages must live in $TEXMFROOT/texmf-dist
  # and sometimes look into $TEXMFROOT/tlpkg (notably fmtutil, updmap look for perl modules in both)
  texmfroot = runCommand "${name}-texmfroot" {
    inherit texmfdist tlpkg;
  } ''
    mkdir -p "$out"
    ln -s "$texmfdist" "$out"/texmf-dist
    ln -s "$tlpkg" "$out"/tlpkg
  '';

  # texlive.combine: expose info and man pages in usual /share/{info,man} location
  doc = buildEnv {
    name = "${name}-doc";

    paths = [ (texmfdist.outPath + "/doc") ];
    extraPrefix = "/share";

    pathsToLink = [
      "/info"
      "/man"
    ];
  };

  meta = {
    description = "TeX Live environment"
      + lib.optionalString withDocs " with documentation"
      + lib.optionalString (withDocs && withSources) " and"
      + lib.optionalString withSources " with sources";
    platforms = lib.platforms.all;
    longDescription = "Contains the following packages and their transitive dependencies:\n - "
      + lib.concatMapStringsSep "\n - "
          (p: p.pname + (lib.optionalString (p.outputSpecified or false) " (${p.tlOutputName or p.outputName})"))
          (requiredTeXPackages tl);
  };

  # emulate split output derivation
  splitOutputs = {
    out = out // { outputSpecified = true; };
    texmfdist = texmfdist // { outputSpecified = true; };
    texmfroot = texmfroot // { outputSpecified = true; };
  } // (lib.genAttrs pkgList.nonEnvOutputs (outName: (buildEnv {
    inherit name;
    paths = builtins.catAttrs "outPath"
      (pkgList.otherOutputs.${outName} or [ ] ++ pkgList.specifiedOutputs.${outName} or [ ]);
    # force the output to be ${outName} or nix-env will not work
    nativeBuildInputs = [ (writeShellScript "force-output.sh" ''
      export out="''${${outName}-}"
    '') ];
    inherit meta passthru;
  }).overrideAttrs { outputs = [ outName ]; } // { outputSpecified = true; }));

  passthru = lib.optionalAttrs (! __combine) (splitOutputs // {
    all = builtins.attrValues splitOutputs;
  }) // {
    # This is set primarily to help find-tarballs.nix to do its job
    requiredTeXPackages = builtins.filter lib.isDerivation (pkgList.bin ++ pkgList.nonbin
      ++ lib.optionals (! __fromCombineWrapper)
        (lib.concatMap (n: (pkgList.otherOutputs.${n} or [ ] ++ pkgList.specifiedOutputs.${n} or [ ]))) pkgList.nonEnvOutputs);
    # useful for inclusion in the `fonts.packages` nixos option or for use in devshells
    fonts = "${texmfroot}/texmf-dist/fonts";
    # support variants attrs, (prev: attrs)
    __overrideTeXConfig = newArgs:
      let appliedArgs = if builtins.isFunction newArgs then newArgs args else newArgs; in
        self (args // { __fromCombineWrapper = false; } // appliedArgs);
    withPackages = reqs: self (args // { requiredTeXPackages = ps: requiredTeXPackages ps ++ reqs ps; __fromCombineWrapper = false; });
  };

  out =
# no indent for git diff purposes
(buildEnv {

  inherit name;

  ignoreCollisions = false;

  # remove fake derivations (without 'outPath') to avoid undesired build dependencies
  paths = builtins.catAttrs "outPath" pkgList.bin
    ++ lib.optional __combine doc;
  pathsToLink = [
    "/"
    "/share/texmf-var/scripts"
    "/share/texmf-var/tex/generic/config"
    "/share/texmf-var/web2c"
    "/share/texmf-config"
    "/bin" # ensure these are writeable directories
  ];

  nativeBuildInputs = [
    makeWrapper
    libfaketime
    tl."texlive.infra" # mktexlsr
    tl.texlive-scripts # fmtutil, updmap
    tl.texlive-scripts-extra # texlinks
    perl
  ];

  inherit meta passthru;

  postBuild =
    # create outputs
  lib.optionalString (! __combine) ''
    for otherOutputName in $outputs ; do
      if [[ "$otherOutputName" == 'out' ]] ; then continue ; fi
      otherOutput="otherOutput_$otherOutputName"
      ln -s "''${!otherOutput}" "''${!otherOutputName}"
    done
  '' +
    # environment variables (note: only export the ones that are used in the wrappers)
  ''
    TEXMFROOT="${texmfroot}"
    TEXMFDIST="${texmfdist}"
    export PATH="$out/bin:$PATH"
    TEXMFSYSCONFIG="$out/share/texmf-config"
    TEXMFSYSVAR="$out/share/texmf-var"
    export TEXMFCNF="$TEXMFSYSVAR/web2c"
  '' +
    # wrap executables with required env vars as early as possible
    # 1. we use the wrapped binaries in the scripts below, to catch bugs
    # 2. we do not want to wrap links generated by texlinks
  ''
    enable -f '${bash}/lib/bash/realpath' realpath
    declare -i wrapCount=0
    for link in "$out"/bin/*; do
      target="$(realpath "$link")"
      if [[ "''${target##*/}" != "''${link##*/}" ]] ; then
        # detected alias with different basename, use immediate target of $link to preserve $0
        # relevant for mktexfmt, repstopdf, ...
        target="$(readlink "$link")"
      fi

      rm "$link"
      makeWrapper "$target" "$link" \
        --inherit-argv0 \
        --prefix PATH : "${
          # very common dependencies that are not detected by tests.texlive.binaries
          lib.makeBinPath ([ coreutils gawk gnugrep gnused ] ++ lib.optional needsGhostscript ghostscript)}:$out/bin" \
        --set-default TEXMFCNF "$TEXMFCNF" \
        --set-default FONTCONFIG_FILE "${
          # necessary for XeTeX to find the fonts distributed with texlive
          makeFontsConf { fontDirectories = [ "${texmfroot}/texmf-dist/fonts" ]; }
        }"
      wrapCount=$((wrapCount + 1))
    done
    echo "wrapped $wrapCount binaries and scripts"
  '' +
    # patch texmf-dist  -> $TEXMFDIST
    # patch texmf-local -> $out/share/texmf-local
    # patch texmf.cnf   -> $TEXMFSYSVAR/web2c/texmf.cnf
    # TODO: perhaps do lua actions?
    # tried inspiration from install-tl, sub do_texmf_cnf
  ''
    mkdir -p "$TEXMFCNF"
    if [ -e "$TEXMFDIST/web2c/texmfcnf.lua" ]; then
      sed \
        -e "s,\(TEXMFOS[ ]*=[ ]*\)[^\,]*,\1\"$TEXMFROOT\",g" \
        -e "s,\(TEXMFDIST[ ]*=[ ]*\)[^\,]*,\1\"$TEXMFDIST\",g" \
        -e "s,\(TEXMFSYSVAR[ ]*=[ ]*\)[^\,]*,\1\"$TEXMFSYSVAR\",g" \
        -e "s,\(TEXMFSYSCONFIG[ ]*=[ ]*\)[^\,]*,\1\"$TEXMFSYSCONFIG\",g" \
        -e "s,\(TEXMFLOCAL[ ]*=[ ]*\)[^\,]*,\1\"$out/share/texmf-local\",g" \
        -e "s,\$SELFAUTOLOC,$out,g" \
        -e "s,selfautodir:/,$out/share/,g" \
        -e "s,selfautodir:,$out/share/,g" \
        -e "s,selfautoparent:/,$out/share/,g" \
        -e "s,selfautoparent:,$out/share/,g" \
        "$TEXMFDIST/web2c/texmfcnf.lua" > "$TEXMFCNF/texmfcnf.lua"
    fi

    sed \
      -e "s,\(TEXMFROOT[ ]*=[ ]*\)[^\,]*,\1$TEXMFROOT,g" \
      -e "s,\(TEXMFDIST[ ]*=[ ]*\)[^\,]*,\1$TEXMFDIST,g" \
      -e "s,\(TEXMFSYSVAR[ ]*=[ ]*\)[^\,]*,\1$TEXMFSYSVAR,g" \
      -e "s,\(TEXMFSYSCONFIG[ ]*=[ ]*\)[^\,]*,\1$TEXMFSYSCONFIG,g" \
      -e "s,\$SELFAUTOLOC,$out,g" \
      -e "s,\$SELFAUTODIR,$out/share,g" \
      -e "s,\$SELFAUTOPARENT,$out/share,g" \
      -e "s,\$SELFAUTOGRANDPARENT,$out/share,g" \
      -e "/^mpost,/d" `# CVE-2016-10243` \
      "$TEXMFDIST/web2c/texmf.cnf" > "$TEXMFCNF/texmf.cnf"
  '' +
    # now filter hyphenation patterns and formats
  (let
    hyphens = lib.filter (p: p.hasHyphens or false && p.tlOutputName or p.outputName == "tex") pkgList.nonbin;
    hyphenPNames = map (p: p.pname) hyphens;
    formats = lib.filter (p: p ? formats && p.tlOutputName or p.outputName == "tex") pkgList.nonbin;
    formatPNames = map (p: p.pname) formats;
    # sed expression that prints the lines in /start/,/end/ except for /end/
    section = start: end: "/${start}/,/${end}/{ /${start}/p; /${end}/!p; };\n";
    script =
      writeText "hyphens.sed" (
        # document how the file was generated (for language.dat)
        "1{ s/^(% Generated by .*)$/\\1, modified by ${if __combine then "texlive.combine" else "Nixpkgs"}/; p; }\n"
        # pick up the header
        + "2,/^% from/{ /^% from/!p; };\n"
        # pick up all sections matching packages that we combine
        + lib.concatMapStrings (pname: section "^% from ${pname}:$" "^% from|^%%% No changes may be made beyond this point.$") hyphenPNames
        # pick up the footer (for language.def)
        + "/^%%% No changes may be made beyond this point.$/,$p;\n"
      );
    scriptLua =
      writeText "hyphens.lua.sed" (
        "1{ s/^(-- Generated by .*)$/\\1, modified by ${if __combine then "texlive.combine" else "Nixpkgs"}/; p; }\n"
        + "2,/^-- END of language.us.lua/p;\n"
        + lib.concatMapStrings (pname: section "^-- from ${pname}:$" "^}$|^-- from") hyphenPNames
        + "$p;\n"
      );
    # formats not being installed must be disabled by prepending #! (see man fmtutil)
    # sed expression that enables the formats in /start/,/end/
    enableFormats = pname: "/^# from ${pname}:$/,/^# from/{ s/^#! //; };\n";
    fmtutilSed =
      writeText "fmtutil.sed" (
        # document how file was generated
        "1{ s/^(# Generated by .*)$/\\1, modified by ${if __combine then "texlive.combine" else "Nixpkgs"}/; }\n"
        # disable all formats, even those already disabled
        + "s/^([^#]|#! )/#! \\1/;\n"
        # enable the formats from the packages being installed
        + lib.concatMapStrings enableFormats formatPNames
        # clean up formats that have been disabled twice
        + "s/^#! #! /#! /;\n"
      );
  in ''
    mkdir -p "$TEXMFSYSVAR/tex/generic/config"
    for fname in tex/generic/config/language.{dat,def}; do
      [[ -e "$TEXMFDIST/$fname" ]] && sed -E -n -f '${script}' "$TEXMFDIST/$fname" > "$TEXMFSYSVAR/$fname"
    done
    [[ -e "$TEXMFDIST"/tex/generic/config/language.dat.lua ]] && sed -E -n -f '${scriptLua}' \
      "$TEXMFDIST"/tex/generic/config/language.dat.lua > "$TEXMFSYSVAR"/tex/generic/config/language.dat.lua
    [[ -e "$TEXMFDIST"/web2c/fmtutil.cnf ]] && sed -E -f '${fmtutilSed}' "$TEXMFDIST"/web2c/fmtutil.cnf > "$TEXMFCNF"/fmtutil.cnf

    # create $TEXMFSYSCONFIG database, make new $TEXMFSYSVAR files visible to kpathsea
    mktexlsr "$TEXMFSYSCONFIG" "$TEXMFSYSVAR"
  '') +
    # generate format links (reads fmtutil.cnf to know which ones) *after* the wrappers have been generated
  ''
    texlinks --quiet "$out/bin"
  '' +
  # texlive postactions (see TeXLive::TLUtils::_do_postaction_script)
  (lib.concatMapStrings (pkg: ''
    postaction='${pkg.postactionScript}'
    case "$postaction" in
      *.pl) postInterp=perl ;;
      *.texlua) postInterp=texlua ;;
      *) postInterp= ;;
    esac
    echo "postaction install script for ${pkg.pname}: ''${postInterp:+$postInterp }$postaction install $TEXMFROOT"
    $postInterp "$TEXMFROOT/$postaction" install "$TEXMFROOT"
  '') (lib.filter (pkg: pkg ? postactionScript) pkgList.tlpkg)) +
    # generate formats
  ''
    # many formats still ignore SOURCE_DATE_EPOCH even when FORCE_SOURCE_DATE=1
    # libfaketime fixes non-determinism related to timestamps ignoring FORCE_SOURCE_DATE
    # we cannot fix further randomness caused by luatex; for further details, see
    # https://salsa.debian.org/live-team/live-build/-/blob/master/examples/hooks/reproducible/2006-reproducible-texlive-binaries-fmt-files.hook.chroot#L52
    # note that calling faketime and fmtutil is fragile (faketime uses LD_PRELOAD, fmtutil calls /bin/sh, causing potential glibc issues on non-NixOS)
    # so we patch fmtutil to use faketime, rather than calling faketime fmtutil
    substitute "$TEXMFDIST"/scripts/texlive/fmtutil.pl fmtutil \
      --replace 'my $cmdline = "$eng -ini ' 'my $cmdline = "faketime -f '"'"'\@1980-01-01 00:00:00 x0.001'"'"' $eng -ini '
    FORCE_SOURCE_DATE=1 TZ= perl fmtutil --sys --all | grep '^fmtutil' # too verbose

    # Disable unavailable map files
    echo y | updmap --sys --syncwithtrees --force 2>&1 | grep '^\(updmap\|  /\)'
    # Regenerate the map files (this is optional)
    updmap --sys --force 2>&1 | grep '^\(updmap\|  /\)'

    # sort entries to improve reproducibility
    [[ -f "$TEXMFSYSCONFIG"/web2c/updmap.cfg ]] && sort -o "$TEXMFSYSCONFIG"/web2c/updmap.cfg "$TEXMFSYSCONFIG"/web2c/updmap.cfg

    mktexlsr "$TEXMFSYSCONFIG" "$TEXMFSYSVAR" # to make sure (of what?)
  '' +
    # remove *-sys scripts since /nix/store is readonly
  ''
    rm "$out"/bin/*-sys
  '' +
  # TODO: a context trigger https://www.preining.info/blog/2015/06/debian-tex-live-2015-the-new-layout/
    # http://wiki.contextgarden.net/ConTeXt_Standalone#Unix-like_platforms_.28Linux.2FMacOS_X.2FFreeBSD.2FSolaris.29

  # MkIV uses its own lookup mechanism and we need to initialize
  # caches for it.
  # We use faketime to fix the embedded timestamps and patch the uuids
  # with some random but constant values.
  ''
    if [[ -e "$out/bin/mtxrun" ]]; then
      substitute "$TEXMFDIST"/scripts/context/lua/mtxrun.lua mtxrun.lua \
        --replace 'cache_uuid=osuuid()' 'cache_uuid="e2402e51-133d-4c73-a278-006ea4ed734f"' \
        --replace 'uuid=osuuid(),' 'uuid="242be807-d17e-4792-8e39-aa93326fc871",'
      FORCE_SOURCE_DATE=1 TZ= faketime -f '@1980-01-01 00:00:00 x0.001' luatex --luaonly mtxrun.lua --generate
    fi
  '' +
  # Get rid of all log files. They are not needed, but take up space
  # and render the build unreproducible by their embedded timestamps
  # and other non-deterministic diagnostics.
  ''
    find "$TEXMFSYSVAR"/web2c -name '*.log' -delete
  '' +
  # link TEXMFDIST in $out/share for backward compatibility
  ''
    ln -s "$TEXMFDIST" "$out"/share/texmf
  ''
  ;
}).overrideAttrs (prev:
  { allowSubstitutes = true; }
  // lib.optionalAttrs (! __combine) ({
    outputs = [ "out" ] ++ pkgList.nonEnvOutputs;
    meta = prev.meta // { inherit (pkgList) outputsToInstall; };
  } // builtins.listToAttrs
    (map (out: { name = "otherOutput_" + out; value = splitOutputs.${out}; }) pkgList.nonEnvOutputs)
  )
);
in out)
