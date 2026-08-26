# Dependency pins for librlnconsumer — subset of logos-delivery's
# nix/deps.nix (itself generated from nimble.lock). Only nim-ffi and its
# transitive closure; regenerate by re-extracting from logos-delivery
# when the nim-ffi pin moves.
{ pkgs }:

{
  ffi = pkgs.fetchgit {
    url = "https://github.com/logos-messaging/nim-ffi";
    rev = "53515de17af0ef3e88b2aec9675b8163dddc14ae";
    sha256 = "0ncf9j7fhgd3nswr4rh19jx77dl974sajphdl04cb602hshgj5ij";
    fetchSubmodules = true;
  };

  chronos = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-chronos";
    rev = "45f43a9ad8bd8bcf5903b42f365c1c879bd54240";
    sha256 = "1v1n59zfzznp97pvwgs9kf136bqmv4x2s2y9f24msspa7qv27w39";
    fetchSubmodules = true;
  };

  chronicles = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-chronicles";
    rev = "27ec507429a4eb81edc20f28292ee8ec420be05b";
    sha256 = "1xx9fcfwgcaizq3s7i3s03mclz253r5j8va38l9ycl19fcbc96z9";
    fetchSubmodules = true;
  };

  taskpools = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-taskpools";
    rev = "9e8ccc754631ac55ac2fd495e167e74e86293edb";
    sha256 = "1y78l33vdjxmb9dkr455pbphxa73rgdsh8m9gpkf4d9b1wm1yivy";
    fetchSubmodules = true;
  };

  cbor_serialization = pkgs.fetchgit {
    url = "https://github.com/vacp2p/nim-cbor-serialization";
    rev = "1664160e04d153573373afddc552b9cbf6fbe4dc";
    sha256 = "0c1rj4fk0fcqvsf0yqhxvm8h10aww75gi4yfsjhlczh88ypywii2";
    fetchSubmodules = true;
  };

  stew = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-stew";
    rev = "4382b18f04b3c43c8409bfcd6b62063773b2bbaa";
    sha256 = "0mx9g5m636h3sk5pllcpylk51brf7lx91izx3gc23k3ih3hrxyk2";
    fetchSubmodules = true;
  };

  results = pkgs.fetchgit {
    url = "https://github.com/arnetheduck/nim-results";
    rev = "df8113dda4c2d74d460a8fa98252b0b771bf1f27";
    sha256 = "1h7amas16sbhlr7zb7n3jb5434k98ji375vzw72k1fsc86vnmcr9";
    fetchSubmodules = true;
  };

  bearssl = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-bearssl";
    rev = "22c6a76ce015bc07e011562bdcfc51d9446c1e82";
    sha256 = "1cvdd7lfrpa6asmc39al3g4py5nqhpqmvypc36r5qyv7p5arc8a3";
    fetchSubmodules = true;
  };

  httputils = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-http-utils";
    rev = "f142cb2e8bd812dd002a6493b6082827bb248592";
    sha256 = "03msj4zdxraz4qx9cidb17g7v0asazxv91nng6xxbzjxz0qaqxw6";
    fetchSubmodules = true;
  };

  serialization = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-serialization";
    rev = "b0f2fa32960ea532a184394b0f27be37bd80248b";
    sha256 = "0wip1fjx7ka39ck1g1xvmyarzq1p5dlngpqil6zff8k8z5skiz27";
    fetchSubmodules = true;
  };

  faststreams = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-faststreams";
    rev = "ce27581a3e881f782f482cb66dc5b07a02bd615e";
    sha256 = "0y6bw2scnmr8cxj4fg18w7f34l2bh9qwg5nhlgd84m9fpr5bqarn";
    fetchSubmodules = true;
  };

  json_serialization = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-json-serialization";
    rev = "c343b0e243d9e17e2c40f3a8a24340f7c4a71d44";
    sha256 = "0i8sq51nqj8lshf6bfixaz9a7sq0ahsbvq3chkxdvv4khsqvam91";
    fetchSubmodules = true;
  };

  unittest2 = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-unittest2";
    rev = "26f2ef3ae0ec72a2a75bfe557e02e88f6a31c189";
    sha256 = "1n8n36kad50m97b64y7bzzknz9n7szffxhp0bqpk3g2v7zpda8sw";
    fetchSubmodules = true;
  };

  testutils = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-testutils";
    rev = "6ce5e5e2301ccbc04b09d27ff78741ff4d352b4d";
    sha256 = "1vbkr6i5yxhc2ai3b7rbglhmyc98f99x874fqdp6a152a6kqgwxy";
    fetchSubmodules = true;
  };
}
