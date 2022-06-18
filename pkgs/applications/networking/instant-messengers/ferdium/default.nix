{ lib, mkFranzDerivation, fetchurl, xorg }:

mkFranzDerivation rec {
  pname = "ferdium";
  name = "Ferdium";
  version = "6.0.0-nightly.65";
  src = fetchurl {
    url = "https://github.com/ferdium/ferdium-app/releases/download/v${version}/ferdium_${version}_amd64.deb";
    sha256 = "sha256-vmu74aLAKGbmRf9hkMUL5VOfi/Cbvdix9MzsZK1qW80=";
  };

  extraBuildInputs = [ xorg.libxshmfence ];

  meta = with lib; {
    description = "All your services in one place built by the community";
    homepage = "https://ferdium.org/";
    license = licenses.asl20;
    maintainers = with maintainers; [ magnouvean ];
    platforms = [ "x86_64-linux" ];
    hydraPlatforms = [ ];
  };
}
