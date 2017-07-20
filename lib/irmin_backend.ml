open Lwt.Infix

module Conf = struct
  let path =
    Irmin.Private.Conf.key ~doc:"Path to filesystem image" "path"
      Irmin.Private.Conf.string "wodan.img"

  let create =
    Irmin.Private.Conf.key ~doc:"Whether to create a fresh filesystem" "create"
      Irmin.Private.Conf.bool false

  let lru_size =
    Irmin.Private.Conf.key ~doc:"How many cache items to keep in the LRU" "lru_size"
      Irmin.Private.Conf.int 1024
end

let config ?(config=Irmin.Private.Conf.empty) ~path ~create ?lru_size () =
  let module C = Irmin.Private.Conf in
  let lru_size = match lru_size with
  |None -> C.default Conf.lru_size
  |Some lru_size -> lru_size
  in
  C.add (C.add (C.add config Conf.lru_size lru_size) Conf.path path) Conf.create create

module type BLOCK_CON = sig
  include Mirage_types_lwt.BLOCK
  (* XXX mirage-block-unix and mirage-block-ramdisk don't have the
   * exact same signature *)
  (*val connect : name:string -> t*)
  val connect : string -> t
end

module type DB = sig
  module Stor : Storage.S
  type t
  val db_root : t -> Stor.root
  val v : Irmin.config -> t Lwt.t
end

module DB_BUILDER
: BLOCK_CON -> Storage.PARAMS -> DB
= functor (B: BLOCK_CON) (P: Storage.PARAMS) ->
struct
  module Stor = Storage.Make(B)(P)

  type t = {
    root: Stor.root;
  }

  let db_root db = db.root

  let v config =
    let module C = Irmin.Private.Conf in
    let path = C.get config Conf.path in
    let create = C.get config Conf.create in
    let lru_size = C.get config Conf.lru_size in
    let disk = B.connect path in
    B.get_info disk >>= function info ->
    let open_arg = if create then
      Storage.FormatEmptyDevice Int64.(div (mul info.size_sectors @@ of_int info.sector_size) @@ of_int Storage.StandardParams.block_size)
    else Storage.OpenExistingDevice in
    Stor.prepare_io open_arg disk lru_size >>= fun (root, _gen) ->
    Lwt.return { root }
end

module RO_BUILDER
: BLOCK_CON -> Storage.PARAMS -> functor (K: Irmin.Hash.S) -> functor (V: Irmin.Contents.Conv) -> sig
  include Irmin.RO
  include DB with type t := t
end with type key = K.t and type value = V.t
= functor (B: BLOCK_CON) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Contents.Conv) ->
struct
  include DB_BUILDER(B)(P)
  type key = K.t
  type value = V.t

  let () = assert (K.digest_size = P.key_size)

  let find db k =
    Stor.lookup (db_root db) @@ Stor.key_of_cstruct @@ K.to_raw k >>= function
    |None -> Lwt.return_none
    |Some v -> Lwt.return_some
      @@ Rresult.R.get_ok @@ Irmin.Type.decode_cstruct V.t @@ Stor.cstruct_of_value v

  let mem db k =
    Stor.mem (db_root db) @@ Stor.key_of_cstruct @@ K.to_raw k
end

module AO_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.AO_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS)
(K: Irmin.Hash.S) (V: Irmin.Contents.Conv) ->
struct
  include RO_BUILDER(B)(P)(K)(V)

  let add db va =
    let raw_v = Irmin.Type.encode_cstruct V.t va in
    let k = K.digest V.t va in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v >>=
      function () -> Lwt.return k
end

module LINK_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.LINK_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS) (K: Irmin.Hash.S) ->
struct
  include RO_BUILDER(B)(P)(K)(K)

  let add db k va =
    let raw_v = K.to_raw va in
    let raw_k = K.to_raw k in
    Stor.insert (db_root db) (Stor.key_of_cstruct raw_k) @@ Stor.value_of_cstruct raw_v
end

module RW_BUILDER
: BLOCK_CON -> Storage.PARAMS -> Irmin.Hash.S -> Irmin.RW_MAKER
= functor (B: BLOCK_CON) (P: Storage.PARAMS) (H: Irmin.Hash.S)
(K: Irmin.Contents.Conv) (V: Irmin.Contents.Conv) ->
struct
  include DB_BUILDER(B)(P)

  let () = assert (H.digest_size = P.key_size)
  let () = assert P.has_tombstone

  type watch = ()
  type key = K.t
  type value = V.t

  let key_to_inner_key k = Stor.key_of_cstruct @@ H.to_raw @@ H.digest K.t k
  let val_to_inner_val va = Stor.value_of_cstruct @@ Irmin.Type.encode_cstruct V.t va
  let _key_to_inner_val k = Stor.value_of_cstruct @@ Irmin.Type.encode_cstruct K.t k
  let val_of_inner_val va =
    Rresult.R.get_ok @@ Irmin.Type.decode_cstruct V.t @@ Stor.cstruct_of_value va

  let set db k va =
    let k = key_to_inner_key k in
    let va = val_to_inner_val va in
    Stor.insert (db_root db) k va

  let watch _db ?init _cb =
    ignore init;
    Lwt.return ()
  let watch_key _db _k ?init _cb =
    ignore init;
    Lwt.return ()
  let unwatch _db () =
    Lwt.return_unit

  let test_and_set db k ~test ~set =
    let k = key_to_inner_key k in
    let test = match test with Some va -> Some (val_to_inner_val va) |None -> None in
    Stor.lookup (db_root db) @@ k >>= function v0 ->
      if v0 = test then begin
        match set with
        |Some va -> Stor.insert (db_root db) k @@ val_to_inner_val va
        |None -> Stor.insert (db_root db) k @@ Stor.value_of_string ""
      end >>= function () -> Lwt.return_true
      else Lwt.return_false

  let remove db k =
    let k = key_to_inner_key k in
    let va = Stor.value_of_string "" in
    Stor.insert (db_root db) k va

  let list _db =
    Lwt.return []

  let find db k =
    Stor.lookup (db_root db) @@ key_to_inner_key k >>= function
    |None -> Lwt.return_none
    |Some va -> Lwt.return_some @@ val_of_inner_val va

  let mem db k =
    Stor.mem (db_root db) @@ key_to_inner_key k
end

