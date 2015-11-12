open V1
open V1_LWT

let sp = Printf.sprintf

let (>>=) = Lwt.bind

let listening_port = 5354

let red fmt    = sp ("\027[31m"^^fmt^^"\027[m")
let green fmt  = sp ("\027[32m"^^fmt^^"\027[m")
let yellow fmt = sp ("\027[33m"^^fmt^^"\027[m")
let blue fmt   = sp ("\027[36m"^^fmt^^"\027[m")

module DNS (C:CONSOLE) (K:KV_RO) (S:STACKV4) = struct

  module U = S.UDPV4

  (** Note that a lot of this logic will eventually move into
      a mirage-dns library, and is just here temporarily *)
  let start c k s =
    begin
      K.size k "test.zone"
      >>= function
      | `Error _ -> Lwt.fail (Failure "test.zone not found")
      | `Ok sz ->
        K.read k "test.zone" 0 (Int64.to_int sz)
        >>= function
        | `Error _ -> Lwt.fail (Failure "test.zone error reading")
        | `Ok pages ->
          Lwt.return (String.concat "" (List.map Cstruct.to_string pages))
    end
    >>= fun zonebuf ->

    let open Dns_server in
    let process = process_of_zonebuf zonebuf in
    let processor = (processor_of_process process :> (module PROCESSOR)) in
    let udp = S.udpv4 s in
    let _ =
      let server = "10.0.1.1" in
      let port = 53 in
      let listening_port = 5359 in
      OS.Time.sleep 3.0 >>= fun () ->
      C.log_s c "Starting client resolver" >>= fun () ->
      let connect_to_resolver server port : Dns_resolver.commfn =
        let dest_ip = Ipaddr.V4.of_string_exn server in
        let txfn buf =
          let buf = Cstruct.of_bigarray buf in
          Cstruct.hexdump buf;
          U.write ~source_port:listening_port ~dest_ip ~dest_port:port udp buf in
        let st, push_st = Lwt_stream.create () in
        S.listen_udpv4 s listening_port (
          fun ~src ~dst ~src_port buf ->
            C.log_s c (sp "resolver response, length %d" (Cstruct.len buf))
            >>= fun () ->
            let ba = Cstruct.to_bigarray buf in
            push_st (Some ba);
            Lwt.return ()
        );
        let rec rxfn f =
          Lwt_stream.get st
          >>= function
          | None -> Lwt.fail (Failure "resolver flow closed")
          | Some buf -> begin
              match f buf with
              | None -> rxfn f
              | Some r -> Lwt.return r
            end
        in
        let timerfn () = OS.Time.sleep 5.0 in
        let cleanfn () = Lwt.return () in
        { Dns_resolver.txfn; rxfn; timerfn; cleanfn }
      in
      let commfn = connect_to_resolver server port in
      let hostname = "dark.recoil.org" in
      let alloc () = (Io_page.get 1 :> Dns.Buf.t) in
      Dns_resolver.gethostbyname ~alloc commfn hostname
      >>= fun ips ->
      Lwt_list.iter_s (fun ip ->
          C.log_s c (sp "%s -> %s" hostname (Ipaddr.to_string ip))) ips
    in
    S.listen_udpv4 s listening_port (
      fun ~src ~dst ~src_port buf ->
        C.log_s c "got udp"
        >>= fun () ->
        let ba = Cstruct.to_bigarray buf in
        let src' = (Ipaddr.V4 dst), listening_port in
        let dst' = (Ipaddr.V4 src), src_port in
        let obuf = (Io_page.get 1 :> Dns.Buf.t) in
        process_query ba (Dns.Buf.length ba) obuf src' dst' processor
        >>= function
        | None ->
          C.log_s c "No response"
        | Some rba ->
          let rbuf = Cstruct.of_bigarray rba in
          U.write ~source_port:listening_port ~dest_ip:src ~dest_port:src_port udp rbuf
    );
    S.listen s
end
