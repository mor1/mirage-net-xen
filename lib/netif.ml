(*
 * Copyright (c) 2010-2013 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf
open OS

type 'a io = 'a Lwt.t
type page_aligned_buffer = Io_page.t
type buffer = Cstruct.t
type macaddr = Macaddr.t

(** IO operation errors *)
type error = [
  | `Unknown of string (** an undiagnosed error *)
  | `Unimplemented     (** operation not yet implemented in the code *)
  | `Disconnected      (** the device has been previously disconnected *)
]

let allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  lwt gnt = Gnt.Gntshr.get () in
  for i = 0 to Cstruct.len x - 1 do
    Cstruct.set_uint8 x i 0
  done;
  Gnt.Gntshr.grant_access ~domid ~writable:true gnt page;
  return (gnt, x)

module RX = struct

  module Proto_64 = struct
    cstruct req {
      uint16_t       id;
      uint16_t       _padding;
      uint32_t       gref
    } as little_endian

    let write ~id ~gref slot =
      set_req_id slot id;
      set_req_gref slot gref;
      id

        cstruct resp {
        uint16_t       id;
        uint16_t       offset;
        uint16_t       flags;
        uint16_t       status
      } as little_endian

    let read slot =
      get_resp_id slot,
      (get_resp_offset slot, get_resp_flags slot, get_resp_status slot)

    let total_size = max sizeof_req sizeof_resp
    let _ = assert(total_size = 8)
  end

  type response = int * int * int

  let create (id, domid) =
    let name = sprintf "Netif.RX.%d" id in
    lwt rx_gnt, buf = allocate_ring ~domid in
    let sring = Ring.Rpc.of_buf ~buf ~idx_size:Proto_64.total_size ~name in
    let fring = Ring.Rpc.Front.init ~sring in
    let client = Lwt_ring.Front.init string_of_int fring in
    return (rx_gnt, fring, client)

end

module TX = struct

  type response = int

  module Proto_64 = struct
    cstruct req {
      uint32_t       gref;
      uint16_t       offset;
      uint16_t       flags;
      uint16_t       id;
      uint16_t       size
    } as little_endian

    type flags =
      |Checksum_blank (* 1 *)
      |Data_validated (* 2 *)
      |More_data      (* 4 *)
      |Extra_info     (* 8 *)

    let flag_more_data = 4

    let write ~gref ~offset ~flags ~id ~size slot =
      set_req_gref slot gref;
      set_req_offset slot offset;
      set_req_flags slot flags;
      set_req_id slot id;
      set_req_size slot size;
      id

        cstruct resp {
        uint16_t       id;
        uint16_t       status
      } as little_endian

    let read slot =
      get_resp_id slot, get_resp_status slot

    let total_size = max sizeof_req sizeof_resp
    let _ = assert(total_size = 12)
  end

  let create (id, domid) =
    let name = sprintf "Netif.TX.%d" id in
    lwt rx_gnt, buf = allocate_ring ~domid in
    let sring = Ring.Rpc.of_buf ~buf ~idx_size:Proto_64.total_size ~name in
    let fring = Ring.Rpc.Front.init ~sring in
    let client = Lwt_ring.Front.init string_of_int fring in
    return (rx_gnt, fring, client)
end

type features = {
  sg: bool;
  gso_tcpv4: bool;
  rx_copy: bool;
  rx_flip: bool;
  smart_poll: bool;
}

type stats = {
  mutable rx_bytes : int64;
  mutable rx_pkts : int32;
  mutable tx_bytes : int64;
  mutable tx_pkts : int32; 
}

type transport = {
  id: int;
  backend_id: int;
  backend: string;
  mac: Macaddr.t;
  tx_fring: (TX.response,int) Ring.Rpc.Front.t;
  tx_client: (TX.response,int) Lwt_ring.Front.t;
  tx_gnt: Gnt.gntref;
  tx_mutex: Lwt_mutex.t; (* Held to avoid signalling between fragments *)
  rx_fring: (RX.response,int) Ring.Rpc.Front.t;
  rx_client: (RX.response,int) Lwt_ring.Front.t;
  rx_map: (int, Gnt.gntref * Io_page.t) Hashtbl.t;
  rx_gnt: Gnt.gntref;
  evtchn: Eventchn.t;
  features: features;
  stats : stats;
}

type t = {
  mutable t: transport;
  mutable resume_fns: (t -> unit Lwt.t) list;
  l : Lwt_mutex.t;
  c : unit Lwt_condition.t;
}

type id = string

let id t = string_of_int t.t.id
let backend_id t = t.t.backend_id

let devices : (id, t) Hashtbl.t = Hashtbl.create 1

let h = Eventchn.init ()

(* Given a VIF ID and backend domid, construct a netfront record for it *)
let plug_inner id =
  lwt xsc = Xs.make () in
  lwt backend_id =
    Xs.(immediate xsc 
          (fun h -> 
             read h (sprintf "device/vif/%d/backend-id" id)))
    >|= int_of_string in
  Printf.printf "Netfront.create: id=%d domid=%d\n%!" id backend_id;
  (* Allocate a transmit and receive ring, and event channel for them *)
  lwt (rx_gnt, rx_fring, rx_client) = RX.create (id, backend_id) in
  lwt (tx_gnt, tx_fring, tx_client) = TX.create (id, backend_id) in
  let tx_mutex = Lwt_mutex.create () in
  let evtchn = Eventchn.bind_unbound_port h backend_id in
  let evtchn_port = Eventchn.to_int evtchn in
  (* Read Xenstore info and set state to Connected *)
  let node = sprintf "device/vif/%d/" id in
  lwt backend = Xs.(immediate xsc (fun h -> read h (node ^ "backend"))) in
  lwt mac =
    Xs.(immediate xsc (fun h -> read h (node ^ "mac"))) 
    >|= Macaddr.of_string
    >>= function
    | None -> Lwt.fail (Failure "invalid mac")
    | Some m -> return m 
  in
  printf "MAC: %s\n%!" (Macaddr.to_string mac);
  Xs.(transaction xsc (fun h ->
      let wrfn k v = write h (node ^ k) v in
      wrfn "tx-ring-ref" (string_of_int tx_gnt) >>
      wrfn "rx-ring-ref" (string_of_int rx_gnt) >>
      wrfn "event-channel" (string_of_int (evtchn_port)) >>
      wrfn "request-rx-copy" "1" >>
      wrfn "feature-rx-notify" "1" >>
      wrfn "feature-sg" "1" >>
      wrfn "state" Device_state.(to_string Connected)
    )) >>
  (* Read backend features *)
  lwt features = Xs.(transaction xsc (fun h ->
      let rdfn k =
        try_lwt
          read h (sprintf "%s/feature-%s" backend k) >>= 
          function
          |"1" -> return true
          |_ -> return false
        with exn -> return false in
      lwt sg = rdfn "sg" in
      lwt gso_tcpv4 = rdfn "gso-tcpv4" in
      lwt rx_copy = rdfn "rx-copy" in
      lwt rx_flip = rdfn "rx-flip" in
      lwt smart_poll = rdfn "smart-poll" in
      return { sg; gso_tcpv4; rx_copy; rx_flip; smart_poll }
    )) in
  let rx_map = Hashtbl.create 1 in
  Printf.printf " sg:%b gso_tcpv4:%b rx_copy:%b rx_flip:%b smart_poll:%b\n"
    features.sg features.gso_tcpv4 features.rx_copy features.rx_flip features.smart_poll;
  Eventchn.unmask h evtchn;
  let stats = { rx_pkts=0l;rx_bytes=0L;tx_pkts=0l;tx_bytes=0L } in
  (* Register callback activation *)
  return { id; backend_id; tx_fring; tx_client; tx_gnt; tx_mutex; 
           rx_gnt; rx_fring; rx_client; rx_map; stats;
           evtchn; mac; backend; features; 
         }

(** Set of active block devices *)
let devices : (int, t) Hashtbl.t = Hashtbl.create 1

let devices_waiters : (int, t Lwt.u Lwt_sequence.t) Hashtbl.t = Hashtbl.create 1

(** Return a list of valid VIFs *)
let enumerate () =
  lwt xs = Xs.make () in
  try_lwt
    Xs.(immediate xs (fun h -> directory h "device/vif"))
  with
  | Xs_protocol.Enoent _ ->
    return []
  | e ->
    printf "Netif.enumerate caught exception: %s\n" (Printexc.to_string e);
    return []

let connect id =
  (* If [id] is an integer, use it. Otherwise default to the first
     available disk. *)
  lwt id' =
    let id = try Some (int_of_string id) with _ -> None in
    match id with 
    | Some id -> 
      return (Some id)
    | None -> 
      enumerate ()
      >>= function
      | [] -> return None 
      | hd::_ -> return (Some (int_of_string hd))
  in
  match id' with
  | Some id' -> begin
      if Hashtbl.mem devices id' then
        return (`Ok (Hashtbl.find devices id'))
      else begin
        printf "Netif.connect %d\n%!" id';
        try_lwt
          lwt t = plug_inner id' in
          let l = Lwt_mutex.create () in
          let c = Lwt_condition.create () in
          let dev = { t; resume_fns=[]; l; c } in
          Hashtbl.add devices id' dev;
          return (`Ok dev)
        with exn ->
          return (`Error (`Unknown (Printexc.to_string exn)))
      end
    end
  | None ->
    lwt all = enumerate () in
    printf "Netif.connect %s: could not find device\n" id;
    return (`Error (`Unknown
                      (Printf.sprintf "device %s not found (available = [ %s ])"
                         id (String.concat ", " all))))

(* Unplug shouldn't block, although the Xen one might need to due
   to Xenstore? XXX *)
let disconnect t =
  printf "Netif: disconnect\n%!";
  Hashtbl.remove devices t.t.id;
  return ()

let notify nf () =
  Eventchn.notify h nf.evtchn

let refill_requests nf =
  let num = Ring.Rpc.Front.get_free_requests nf.rx_fring in
  if num > 0 then
    lwt grefs = Gnt.Gntshr.get_n num in
    let pages = Io_page.pages num in
    List.iter
      (fun (gref, page) ->
         let id = gref mod (1 lsl 16) in
         Gnt.Gntshr.grant_access ~domid:nf.backend_id ~writable:true gref page;
         Hashtbl.add nf.rx_map id (gref, page);
         let slot_id = Ring.Rpc.Front.next_req_id nf.rx_fring in
         let slot = Ring.Rpc.Front.slot nf.rx_fring slot_id in
         ignore(RX.Proto_64.write ~id ~gref:(Int32.of_int gref) slot)
      ) (List.combine grefs pages);
    if Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring
    then notify nf ();
    return ()
  else return ()

let rx_poll nf fn =
  Ring.Rpc.Front.ack_responses nf.rx_fring (fun slot ->
      let id,(offset,flags,status) = RX.Proto_64.read slot in
      let gref, page = Hashtbl.find nf.rx_map id in
      Hashtbl.remove nf.rx_map id;
      Gnt.Gntshr.end_access gref;
      Gnt.Gntshr.put gref;
      match status with
      |sz when status > 0 ->
        let packet = Cstruct.sub (Io_page.to_cstruct page) 0 sz in
        nf.stats.rx_pkts <- Int32.succ nf.stats.rx_pkts;
        nf.stats.rx_bytes <- Int64.add nf.stats.rx_bytes (Int64.of_int sz);
        ignore_result 
          (try_lwt fn packet
           with exn -> return (printf "RX exn %s\n%!" (Printexc.to_string exn)))
      |err -> printf "RX error %d\n%!" err
    )

let tx_poll nf =
  Lwt_ring.Front.poll nf.tx_client TX.Proto_64.read

(* Push a single page to the ring, but no event notification *)
let write_request ?size ~flags nf page =
  lwt gref = Gnt.Gntshr.get () in
  (* This grants access to the *base* data pointer of the page *)
  (* XXX: another place where we peek inside the cstruct *)
  Gnt.Gntshr.grant_access ~domid:nf.t.backend_id ~writable:false gref page.Cstruct.buffer;
  let size = match size with |None -> Cstruct.len page |Some s -> s in
  (* XXX: another place where we peek inside the cstruct *)
  nf.t.stats.tx_pkts <- Int32.succ nf.t.stats.tx_pkts;
  nf.t.stats.tx_bytes <- Int64.add nf.t.stats.tx_bytes (Int64.of_int size);
  let offset = page.Cstruct.off in
  lwt replied = Lwt_ring.Front.write nf.t.tx_client
      (TX.Proto_64.write ~id:gref ~gref:(Int32.of_int gref) ~offset ~flags ~size) in
  (* request has been written; when replied returns we have a reply *)
  let replied =
    try_lwt
      lwt _ = replied in
      Gnt.Gntshr.end_access gref;
      Gnt.Gntshr.put gref;
      return ()
    with Lwt_ring.Shutdown ->
      Gnt.Gntshr.put gref;
      fail Lwt_ring.Shutdown
       | e ->
         Gnt.Gntshr.end_access gref;
         Gnt.Gntshr.put gref;
         fail e in
  return replied

(* Transmit a packet from buffer, with offset and length *)  
let rec write_already_locked nf page =
  try_lwt
    lwt th = write_request ~flags:0 nf page in
    Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
    lwt () = th in
    (* all fragments acknowledged, resources cleaned up *)
    return ()
  with | Lwt_ring.Shutdown -> write_already_locked nf page

let write nf page =
  Lwt_mutex.with_lock nf.t.tx_mutex
    (fun () ->
       write_already_locked nf page
    )

(* Transmit a packet from a list of pages *)
let writev nf pages =
  Lwt_mutex.with_lock nf.t.tx_mutex
    (fun () ->
       let rec wait_for_free_tx event n =
         let numfree = Ring.Rpc.Front.get_free_requests nf.t.tx_fring in 
         if n >= numfree then 
           lwt event = Activations.after nf.t.evtchn event in
           wait_for_free_tx event n
         else
           return ()
       in
       let numneeded = List.length pages in
       wait_for_free_tx Activations.program_start numneeded >>
       match pages with
       |[] -> return ()
       |[page] ->
         (* If there is only one page, then just write it normally *)
         write_already_locked nf page
       |first_page::other_pages ->
         (* For Xen Netfront, the first fragment contains the entire packet
          * length, which is the backend will use to consume the remaining
          * fragments until the full length is satisfied *)
         let size = Cstruct.lenv pages in
         lwt first_th =
           write_request ~flags:TX.Proto_64.flag_more_data ~size nf first_page in
         let rec xmit = function
           | [] -> return []
           | hd :: [] ->
             lwt th = write_request ~flags:0 nf hd in
             return [ th ]
           | hd :: tl ->
             lwt next_th = write_request ~flags:TX.Proto_64.flag_more_data nf hd in
             lwt rest = xmit tl in
             return (next_th :: rest) in
         lwt rest_th = xmit other_pages in
         (* All fragments are now written, we can now notify the backend *)
         Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
         return ()
    )

let wait_for_plug nf =
  Printf.printf "Wait for plug...\n";
  Lwt_mutex.with_lock nf.l (fun () ->
      while_lwt not (Eventchn.is_valid nf.t.evtchn) do
        Lwt_condition.wait ~mutex:nf.l nf.c
      done)

let listen nf fn =
  (* Listen for the activation to poll the interface *)
  let rec poll_t event t =
    lwt () = refill_requests t in
    rx_poll t fn;
    tx_poll t;
    (* Evtchn.notify nf.t.evtchn; *)
    lwt (event, new_t) =
      lwt event = Activations.after t.evtchn event in
      return (event, t)
    in poll_t event new_t
  in
  poll_t Activations.program_start nf.t

(** Return a list of valid VIFs *)
let enumerate () =
  Xs.make ()
  >>= fun xsc ->
  catch
    (fun () -> 
       Xs.(immediate xsc 
             (fun h -> directory h "device/vif")) 
       >|= (List.map int_of_string) )
    (fun _ -> return [])

let resume (id,t) =
  lwt transport = plug_inner id in
  let old_transport = t.t in
  t.t <- transport;
  lwt () = Lwt_list.iter_s (fun fn -> fn t) t.resume_fns in
  lwt () = Lwt_mutex.with_lock t.l
      (fun () -> Lwt_condition.broadcast t.c (); return ()) in
  Lwt_ring.Front.shutdown old_transport.rx_client;
  Lwt_ring.Front.shutdown old_transport.tx_client;
  return ()

let resume () =
  let devs = Hashtbl.fold (fun k v acc -> (k,v)::acc) devices [] in
  Lwt_list.iter_p (fun (k,v) -> resume (k,v)) devs

let add_resume_hook t fn =
  t.resume_fns <- fn::t.resume_fns

(* Type of callback functions for [create]. *)
type callback = id -> t -> unit Lwt.t

(* The Xenstore MAC address is colon separated, very helpfully *)
let mac nf = nf.t.mac

let get_stats_counters t = t.t.stats

let reset_stats_counters t =
  t.t.stats.rx_bytes <- 0L;
  t.t.stats.rx_pkts  <- 0l;
  t.t.stats.tx_bytes <- 0L;
  t.t.stats.tx_pkts  <- 0l

let _ =
  printf "Netif: add resume hook\n%!";
  Sched.add_resume_hook resume
