open V1
open V1_LWT

let (>>=) = Lwt.bind

(* HTTP handler *)
module type HTTP = sig
  include Cohttp_lwt.Server
  val listen: t -> IO.conn -> unit Lwt.t
end

module Dispatch (C: CONSOLE) (FS: KV_RO) (S: HTTP) = struct

  let log c fmt = Printf.ksprintf (C.log c) fmt

  let read_fs fs name =
    FS.size fs name >>= function
      | `Error (FS.Unknown_key _) ->
        Lwt.fail (Failure ("read " ^ name))
      | `Ok size ->
        FS.read fs name 0 (Int64.to_int size) >>= function
        | `Error (FS.Unknown_key _) -> Lwt.fail (Failure ("read " ^ name))
        | `Ok bufs -> Lwt.return ((Magic_mime.lookup name), (Cstruct.copyv bufs))

  (* dispatch files *)
  let dispatcher fs ?header uri = 
    let path = 
      let p = Uri.path uri in 
      match p.[ (String.length p) - 1 ] with  
      | '/' ->  p ^ "index.html"
      | _ -> p 
    in 
    let read_fs_path fs path = 
      read_fs fs path >>= fun (mimetype, body) ->
        let headers = Cohttp.Header.add_opt header "content-type" mimetype in
        S.respond_string ~status:`OK ~body ~headers ()
    in 
    Lwt.catch
      (fun () -> read_fs_path fs path) 
      (fun exn ->  
        Lwt.catch 
        (fun () -> read_fs_path fs (path ^ "/index.html"))
        (fun exn -> S.respond_not_found ()))

  (* Redirect to the same address, but in https. *)
  let redirect uri =
    let new_uri = Uri.with_scheme uri (Some "https") in
    let headers =
      Cohttp.Header.init_with "location" (Uri.to_string new_uri)
    in
    S.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let serve c flow f =
    let callback (_, cid) request body =
      let uri = Cohttp.Request.uri request in
      let cid = Cohttp.Connection.to_string cid in
      log c "[%s] serving %s." cid (Uri.to_string uri);
      f uri 
    in
    let conn_closed (_,cid) =
      let cid = Cohttp.Connection.to_string cid in
      log c "[%s] closing." cid
    in
    let http = S.make ~conn_closed ~callback () in
    S.listen http flow

end

(* HTTP *)
module HTTP
    (C : CONSOLE) (S : STACKV4)
    (DATA : KV_RO)
    (Clock : CLOCK) =
struct

  module Http     = Cohttp_mirage.Server(S.TCPV4)
  module Dispatch = Dispatch(C)(DATA)(Http)

  let start c stack data _clock =
    let http flow = Dispatch.serve c flow (Dispatch.dispatcher data) in
    S.listen_tcpv4 stack ~port:80 http;
    S.listen stack

end

(* HTTPS *)
module HTTPS
    (C : CONSOLE) (S : STACKV4)
    (DATA : KV_RO) (KEYS: KV_RO)
    (Clock : CLOCK) =
struct

  module TCP  = S.TCPV4
  module TLS  = Tls_mirage.Make (TCP)
  module X509 = Tls_mirage.X509 (KEYS) (Clock)

  module Http  = Cohttp_mirage.Server(TCP)
  module Https = Cohttp_mirage.Server(TLS)

  module Dispatch_http  = Dispatch(C)(DATA)(Http)
  module Dispatch_https = Dispatch(C)(DATA)(Https)

  let log c fmt = Printf.ksprintf (C.log c) fmt

  let with_tls c cfg tcp ~f =
    let peer, port = TCP.get_dest tcp in
    let log str = log c "[%s:%d] %s" (Ipaddr.V4.to_string peer) port str in
    let with_tls_server k = TLS.server_of_flow cfg tcp >>= k in
    with_tls_server @@ function
    | `Error _ -> log "TLS failed"; TCP.close tcp
    | `Ok tls  -> log "TLS ok"; f tls >>= fun () -> TLS.close tls
    | `Eof     -> log "TLS eof"; TCP.close tcp

  let tls_init kv =
    X509.certificate kv `Default >>= fun cert ->
    let conf = Tls.Config.server ~certificates:(`Single cert) () in
    Lwt.return conf

  let start c stack data keys _clock =
    tls_init keys >>= fun cfg ->
    (* 31536000 seconds is roughly a year *)
    let header = Cohttp.Header.init_with "Strict-Transport-Security" "max-age=31536000" in
    let https flow = Dispatch_https.serve c flow (Dispatch_https.dispatcher ~header data ) in
    let http  flow = Dispatch_http.serve  c flow Dispatch_http.redirect in
    S.listen_tcpv4 stack ~port:443 (with_tls c cfg ~f:https);
    S.listen_tcpv4 stack ~port:80  http;
    S.listen stack

end
