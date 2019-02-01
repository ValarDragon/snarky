open Core_kernel
open Parsetypes
open Parsetypes.Type
open Environ

type error =
  | Check_failed_aux of type_expr * type_expr
  | Check_failed of type_expr * type_expr * type_expr * type_expr
  | Tdefer_found of string
  | Tpoly_found of string
  | Tvar_expected of string
  | Unbound_constructor of string
  | Unbound_value of string
  | Unbound_record_field of string
  | Empty_record

exception Error of Location.t * error

let type_print typ =
  let typ = To_ocaml.of_typ typ in
  Pprintast.core_type Format.std_formatter typ ;
  Format.pp_print_newline Format.std_formatter ()

let rec copy_type depth typ =
  let loc = typ.type_loc in
  match typ.type_desc with
  | Tvar _ -> typ
  | Tpoly (var, typ) ->
      let newvar = mk_var ~loc ~depth None in
      let oldvar = var.type_desc in
      var.type_desc <- Tdefer newvar ;
      let typ = copy_type depth typ in
      var.type_desc <- oldvar ;
      mk ~loc (Tpoly (newvar, typ))
  | Tdefer typ -> typ
  | Tconstr _ -> mk ~loc typ.type_desc
  | Tarrow (typ1, typ2) ->
      mk ~loc (Tarrow (copy_type depth typ1, copy_type depth typ2))
  | Ttuple typs -> mk ~loc (Ttuple (List.map ~f:(copy_type depth) typs))

let rec check_type_aux typ constr_typ =
  let loc = constr_typ.type_loc in
  if not (phys_equal typ constr_typ) then
    match (typ.type_desc, constr_typ.type_desc) with
    | Tpoly (_, typ), _ -> check_type_aux typ constr_typ
    | _, Tpoly (_, constr_typ) -> check_type_aux typ constr_typ
    | ( Tconstr {constr_type_decl= typ_decl; _}
      , Tconstr {constr_type_decl= constr_typ_decl; _} ) -> (
        if not (Int.equal typ_decl.type_decl_id constr_typ_decl.type_decl_id)
        then
          match (typ_decl.type_decl_desc, constr_typ_decl.type_decl_desc) with
          | Alias typ, _ ->
              typ_decl.type_decl_in_recursion <- true ;
              check_type_aux typ constr_typ ;
              typ_decl.type_decl_in_recursion <- false
          | _, Alias constr_typ ->
              constr_typ_decl.type_decl_in_recursion <- true ;
              check_type_aux typ constr_typ ;
              constr_typ_decl.type_decl_in_recursion <- false
          | _, _ -> raise (Error (loc, Check_failed_aux (typ, constr_typ))) )
    | Tarrow (typ1, typ2), Tarrow (constr_typ1, constr_typ2) ->
        check_type_aux typ1 constr_typ1 ;
        check_type_aux typ2 constr_typ2
    | Ttuple typs, Ttuple constr_typs -> (
      match List.iter2 ~f:check_type_aux typs constr_typs with
      | Ok _ -> ()
      | Unequal_lengths ->
          raise (Error (loc, Check_failed_aux (typ, constr_typ))) )
    | Tdefer _, _ | _, Tdefer _ -> raise (Error (loc, Tdefer_found __LOC__))
    | Tvar data, Tvar constr_data -> (
      match (data.instance, constr_data.instance) with
      | None, None ->
          if data.depth <= constr_data.depth then
            constr_data.instance <- Some typ
          else data.instance <- Some constr_typ
      | Some typ', None ->
          if data.depth <= constr_data.depth then
            constr_data.instance <- Some typ
          else (
            constr_data.instance <- Some typ' ;
            data.instance <- Some constr_typ )
      | None, Some constr_typ' ->
          if constr_data.depth <= data.depth then
            data.instance <- Some constr_typ
          else (
            data.instance <- Some constr_typ' ;
            constr_data.instance <- Some typ )
      | Some typ', Some _constr_typ' ->
          let in_recursion = typ.in_recursion in
          typ.in_recursion <- true ;
          data.instance <- Some constr_typ ;
          check_type_aux typ' constr_typ ;
          typ.in_recursion <- in_recursion ;
          if data.depth < constr_data.depth then (
            data.instance <- constr_data.instance ;
            constr_data.instance <- Some typ ) )
    | _, Tvar constr_data -> (
      match constr_data.instance with
      | None -> constr_data.instance <- Some typ
      | Some constr_typ' ->
          if constr_typ.in_recursion then ()
            (* Don't do anything, or we'll loop forever. *)
          else check_type_aux typ constr_typ' )
    | Tvar data, _ -> (
      match data.instance with
      | None -> data.instance <- Some constr_typ
      | Some typ' ->
          let in_recursion = typ.in_recursion in
          typ.in_recursion <- true ;
          data.instance <- Some constr_typ ;
          check_type_aux typ' constr_typ ;
          typ.in_recursion <- in_recursion )
    | _, _ -> raise (Error (loc, Check_failed_aux (typ, constr_typ)))

let check_type ~loc typ constr_typ =
  match check_type_aux typ constr_typ with
  | exception Error (_, Check_failed_aux (typ', constr_typ')) ->
      raise (Error (loc, Check_failed (typ, constr_typ, typ', constr_typ')))
  | _ -> constr_typ

let rec unify_after_parse' env typ =
  match typ.type_desc with
  | Tpoly (_, typ) -> unify_after_parse' env typ
  | Tvar {name= Some name; _} -> (
    match Environ.find_type_var name env with
    | Some (_, var) -> (var, env, Base.Set.empty (module Type))
    | None ->
        let typ = mk_var ~loc:typ.type_loc ~depth:env.depth (Some name) in
        let env = Environ.add_type_var ~user:true ~name typ env in
        (typ, env, Base.Set.singleton (module Type) typ) )
  | Tvar {name= None; _} ->
      let typ = mk_var ~loc:typ.type_loc ~depth:env.depth None in
      (typ, env, Base.Set.singleton (module Type) typ)
  | Tconstr data ->
      ( match Environ.find_type data.constr_ident env with
      | Some type_decl -> data.constr_type_decl <- type_decl
      | None ->
        let ident = data.constr_ident in
        raise (Error (ident.loc, Unbound_constructor ident.txt))) ;
      (typ, env, Base.Set.empty (module Type))
  | Tarrow (typ1, typ2) ->
      let typ1, env, vars1 = unify_after_parse' env typ1 in
      let typ2, env, vars2 = unify_after_parse' env typ2 in
      typ.type_desc <- Tarrow (typ1, typ2) ;
      (typ, env, Base.Set.union vars1 vars2)
  | Ttuple typs ->
      let rev_typs, env, vars =
        List.fold_left typs
          ~init:([], env, Base.Set.empty (module Type))
          ~f:(fun (rev_typs, env, vars) typ ->
            let typ, env, vars' = unify_after_parse' env typ in
            (typ :: rev_typs, env, Base.Set.union vars vars') )
      in
      typ.type_desc <- Ttuple (List.rev rev_typs) ;
      (typ, env, vars)
  | Tdefer typ -> unify_after_parse' env typ

let rec type_vars typ =
  match typ.type_desc with
  | Tpoly (_, typ) -> type_vars typ
  | Tvar _ -> Base.Set.singleton (module Type) typ
  | Tconstr _ -> Base.Set.empty (module Type)
  | Tarrow (typ1, typ2) -> Base.Set.union (type_vars typ1) (type_vars typ2)
  | Ttuple typs ->
      List.fold_left typs
        ~init:(Base.Set.empty (module Type))
        ~f:(fun vars typ -> Base.Set.union vars (type_vars typ))
  | Tdefer typ -> type_vars typ

let unify_after_parse env typ =
  let typ, env, _ = unify_after_parse' env typ in
  (typ, env)

let polymorphise typ vars =
  let loc = typ.type_loc in
  let typ = ref typ in
  Base.Set.iter vars ~f:(fun var -> typ := mk ~loc (Tpoly (var, !typ))) ;
  !typ

let rec strip_polymorphism typ =
  match typ.type_desc with
  | Tpoly (_, typ) -> strip_polymorphism typ
  | _ -> typ

let rec rev_polymorphic_vars typ =
  match typ.type_desc with
  | Tpoly (var, typ) -> var :: rev_polymorphic_vars typ
  | _ -> []

let rec add_rev_polymorphic_vars ~loc typ vars =
  match vars with
  | [] -> typ
  | var :: vars ->
      add_rev_polymorphic_vars ~loc (Type.mk ~loc (Tpoly (var, typ))) vars

let copy_polymorphism ~loc source_typ typ =
  add_rev_polymorphic_vars ~loc typ (rev_polymorphic_vars source_typ)

let unify_and_polymorphise_after_parse env typ =
  let typ, _, vars = unify_after_parse' env typ in
  (polymorphise typ vars, env)

let next_type_var i =
  if i < 25 then String.make 1 (Char.of_int_exn (Char.to_int 'a' + i))
  else Printf.sprintf "%d" (i - 24)

let rec find_next_free_var ~loc typ_vars vars_size =
  let var = next_type_var vars_size in
  if Map.mem typ_vars var then find_next_free_var ~loc typ_vars (vars_size + 1)
  else (Location.mkloc var loc, vars_size)

(** Accepts a [type_expr] of a [Tvar] as an argument.
    Capture the set of all the irreducible type variables that make up the
    instance of the type variable.
    This may include the type variable itself, if it is self-referential or has
    no instance. *)
let capture_type_vars vars typ =
  let rec capture_type_vars depth typ vars removed_vars =
    match typ.type_desc with
    | Tpoly _ -> raise (Error (typ.type_loc, Tpoly_found __LOC__))
    | Tdefer _ -> raise (Error (typ.type_loc, Tdefer_found __LOC__))
    | Tvar {instance= Some typ'; depth= depth'; _} ->
        if Set.mem vars typ then vars
        else if Set.mem removed_vars typ then
          (* Variable is self-referential. *)
          if depth <= depth' then Set.add vars typ else vars
        else capture_type_vars depth typ' vars (Set.add removed_vars typ)
    | Tvar _ -> Set.add vars typ
    | Tconstr _ -> Set.empty (module Type)
    | Tarrow (typ1, typ2) ->
        let vars = capture_type_vars depth typ1 vars removed_vars in
        capture_type_vars depth typ2 vars removed_vars
    | Ttuple typs ->
        List.fold_left typs
          ~init:(Set.empty (module Type))
          ~f:(fun vars typ -> capture_type_vars depth typ vars removed_vars)
  in
  let var_set = Set.singleton (module Type) typ in
  match typ.type_desc with
  | Tvar {instance= Some typ; depth; _} -> (
    try capture_type_vars depth typ vars var_set with a ->
      pp_type_expr Format.std_formatter typ ;
      raise a )
  | Tvar _ -> var_set
  | _ -> raise (Error (typ.type_loc, Tvar_expected __LOC__))

let reduce_type_vars typ =
  let rec reduce_type_vars typ vars =
    match typ.type_desc with
    | Tpoly (var, typ) -> reduce_type_vars typ (Set.add vars var)
    | _ -> Set.fold vars ~init:(Set.empty (module Type)) ~f:capture_type_vars
  in
  reduce_type_vars typ (Set.empty (module Type))

let rec name_type_variables typ ({typ_vars; vars_size; _} as env) =
  let loc = typ.type_loc in
  match typ.type_desc with
  | Tvar ({name= None; _} as data) ->
      let name, vars_size = find_next_free_var ~loc typ_vars vars_size in
      typ.type_desc <- Tvar {data with name= Some name} ;
      let env = Environ.add_type_var ~user:true ~name typ env in
      {env with vars_size; typ_vars}
  | Tvar {name= Some name; _} -> (
      let old = Environ.find_type_var name env in
      match old with
      | Some (`Generated, ({type_desc= Tvar data; _} as old)) ->
          old.type_desc <- Tvar {data with name= None} ;
          let env = Environ.add_type_var ~user:true ~name typ env in
          name_type_variables old env
      | _ -> env )
  | Tpoly (_var, typ) -> name_type_variables typ env
  | Tconstr _ -> env
  | Tarrow (typ1, typ2) ->
      let env = name_type_variables typ1 env in
      name_type_variables typ2 env
  | Ttuple typs ->
      List.fold_left typs ~init:env ~f:(fun env typ ->
          name_type_variables typ env )
  | Tdefer typ -> name_type_variables typ env

let mk_arrow ~loc typ1 typ2 =
  let rev_vars1 = rev_polymorphic_vars typ1 in
  let typ1 = strip_polymorphism typ1 in
  let rev_vars2 = rev_polymorphic_vars typ2 in
  let typ2 = strip_polymorphism typ2 in
  let typ = mk ~loc (Tarrow (typ1, typ2)) in
  let typ = add_rev_polymorphic_vars ~loc typ rev_vars2 in
  add_rev_polymorphic_vars ~loc typ rev_vars1

let get_name name env =
  match Environ.find_name name env with
  | Some (`Copy, typ) -> copy_type env.depth typ
  | Some (`NoCopy, typ) -> typ
  | None -> raise (Error (name.loc, Unbound_value name.txt))

let get_field_type ~loc field typ env =
  let record_typ, field_typ =
    match
      (Environ.find_record_type field env, Environ.find_field_type field env)
    with
    | Some typ, Some field_type -> (typ, field_type)
    | _, _ -> raise (Error (field.loc, Unbound_record_field field.txt))
  in
  let field_arrow = mk_arrow ~loc record_typ field_typ in
  let field_arrow = copy_type env.depth field_arrow in
  match
    check_type ~loc field_arrow (mk ~loc (Tarrow (typ, mk_var ~loc None)))
  with
  | {type_desc= Tarrow (_, field_typ); _} -> field_typ
  | _ -> failwith "Met constraint Tarrow, but didn't match Tarrow.."

let add_type_final name typ env =
  let typ_vars = reduce_type_vars typ in
  let typ = polymorphise typ typ_vars in
  let env = name_type_variables typ env in
  Environ.add_name name (`Copy, typ) env

let add_type_in_progress name typ env =
  Environ.add_name name (`NoCopy, typ) env

let constant_type c =
  match c with
  | Pconst_integer _ -> Environ.Core.Type.int
  | Pconst_char _ -> Environ.Core.Type.char
  | Pconst_string _ -> Environ.Core.Type.string
  | Pconst_float _ -> Environ.Core.Type.float

let rec check_pattern ~add ~after_parse env typ pat =
  let loc = pat.pat_loc in
  match pat.pat_desc with
  | PAny -> env
  | PConstant c ->
      let _typ = check_type ~loc typ (constant_type c) in
      env
  | PVariable str -> add str typ env
  | PConstraint ({pcon_pat= p; pcon_typ= constr_typ} as data) ->
      let constr_typ, env = after_parse env constr_typ in
      data.pcon_typ <- constr_typ ;
      let typ = check_type ~loc typ constr_typ in
      check_pattern ~add ~after_parse env typ p
  | PRecord (fields, _) ->
      List.fold_left fields ~init:env ~f:(fun env (ident, p) ->
          let typ = get_field_type ~loc ident typ env in
          check_pattern ~add ~after_parse env typ p )
  | POr (p1, p2) ->
      let env = check_pattern ~add ~after_parse env typ p1 in
      check_pattern ~add ~after_parse env typ p2
  | PTuple ps ->
      let types =
        List.map ps ~f:(fun _ -> mk_var ~loc ~depth:env.depth None)
      in
      let tuple_typ = mk ~loc (Ttuple types) in
      let _tuple_typ = check_type ~loc typ tuple_typ in
      List.fold2_exn ~init:env types ps ~f:(check_pattern ~add ~after_parse)

let rec get_expression env exp =
  let loc = exp.exp_loc in
  match exp.exp_desc with
  | Constant c -> constant_type c
  | Variable name -> get_name name env
  | Apply (f, xs) ->
      let f_typ = get_expression env f in
      let rec apply_typ xs f_typ =
        match xs with
        | [] -> f_typ
        | x :: xs -> (
            let x_typ = get_expression env x in
            match
              check_type ~loc f_typ
                (mk ~loc (Tarrow (x_typ, mk_var ~loc None)))
            with
            | {type_desc= Tarrow (_, f_typ); _} -> apply_typ xs f_typ
            | _ -> failwith "Met constraint Tarrow, but didn't match Tarrow.."
            )
      in
      apply_typ xs f_typ
  | Fun (p, body) ->
      (* In OCaml, function arguments can't be polymorphic, so each check refines
       them rather than instanciating the parameters. *)
      let env = {env with depth= env.depth + 1} in
      let p_typ = mk_var ~loc None in
      let env =
        check_pattern ~add:add_type_in_progress ~after_parse:unify_after_parse
          env p_typ p
      in
      let body_typ = get_expression env body in
      mk_arrow ~loc p_typ body_typ
  | Seq (e1, e2) ->
      let _ = get_expression env e1 in
      get_expression env e2
  | Let (p, e1, e2) ->
      let env = check_binding env p e1 in
      get_expression env e2
  | Constraint {econ_exp= e; econ_typ= typ} ->
      let e_typ = get_expression env e in
      check_type ~loc e_typ typ
  | Tuple es ->
      mk ~loc
        (Ttuple
           (List.map es ~f:(fun e -> strip_polymorphism (get_expression env e))))
  | Record_literal {record_fields= {field_ident=field; _} :: _; _} -> (
    match Environ.find_record_type field env with
    | Some typ -> copy_type env.depth typ
    | None -> raise (Error (field.loc, Unbound_record_field field.txt)))
  | Record_literal _ -> raise (Error (exp.exp_loc, Empty_record))
  | Field (e, field) ->
      let e_typ = get_expression env e in
      get_field_type ~loc field e_typ env
  | Match (e, cases) ->
      let e_typ = get_expression env e in
      let depth = env.depth in
      let env = {env with depth= depth + 1} in
      let envs =
        List.map cases ~f:(fun (p, _) ->
            let e_typ = copy_type depth e_typ in
            let env =
              check_pattern env e_typ p
                ~after_parse:unify_and_polymorphise_after_parse
                ~add:add_type_final
            in
            Environ.push_match_instances (rev_polymorphic_vars e_typ) env )
      in
      List.fold2_exn envs cases ~init:(mk_var ~loc ~depth None)
        ~f:(fun typ env (_, case_e) ->
          let case_e_typ = get_expression env case_e in
          let instances, _env = Environ.pop_match_instances env in
          ignore
            (List.map instances ~f:(fun var ->
                 match var.type_desc with
                 | Tvar data -> data.instance <- None
                 | _ -> failwith "Expected a Tvar from env.match_instances" )) ;
          check_type ~loc:case_e.exp_loc case_e_typ typ )

and check_binding (env : 's) p e : 's =
  let e_type = get_expression env e in
  check_pattern ~add:add_type_final
    ~after_parse:unify_and_polymorphise_after_parse env e_type p

let field_after_parse env field =
  { field with
    field_type=
      (let typ, _ = unify_after_parse env field.field_type in
       typ) }

let ctor_after_parse env type_decl ctor =
  let constr_decl_args =
    match ctor.constr_decl_args with
    | Constr_tuple args ->
        let args =
          List.map args ~f:(fun arg ->
              let typ, _ = unify_after_parse env arg in
              typ )
        in
        Constr_tuple args
    | Constr_record fields ->
        let fields = List.map fields ~f:(field_after_parse env) in
        Constr_record fields
  in
  let constr_decl_return =
    Option.map ctor.constr_decl_return ~f:(fun type_ret ->
        let decl_loc = type_decl.type_decl_loc in
        let ctor_loc = ctor.constr_decl_loc in
        let typ =
          mk_constr' ~loc:decl_loc ~decl:type_decl
            (Location.mkloc "<internal>" decl_loc)
        in
        check_type ~loc:ctor_loc type_ret typ )
  in
  {ctor with constr_decl_args; constr_decl_return}

let type_decl_after_parse env name type_decl =
  let loc = type_decl.type_decl_loc in
  match type_decl.type_decl_desc with
  | Abstract -> type_decl
  | Alias typ ->
      let typ, _ = unify_after_parse env typ in
      TypeDecl.mk ~loc (Alias typ)
  | Record fields ->
      let fields = List.map ~f:(field_after_parse env) fields in
      TypeDecl.mk ~loc (Record fields)
  | VariantRecord fields ->
      let fields = List.map ~f:(field_after_parse env) fields in
      TypeDecl.mk ~loc (VariantRecord fields)
  | Variant ctors ->
      let env' = Environ.register_type name type_decl env in
      let ctors = List.map ~f:(ctor_after_parse env' type_decl) ctors in
      TypeDecl.mk ~loc (Variant ctors)

let check_statement env stmt =
  match stmt.stmt_desc with
  | Value (p, e) -> check_binding env p e
  | Type (x, typ_decl) ->
      let typ_decl = type_decl_after_parse env x typ_decl in
      Environ.register_type x typ_decl env

let check (ast : statement list) =
  List.fold_left ast ~init:Environ.Core.env ~f:(fun env stmt ->
      check_statement env stmt )

(* Error handling *)

open Format

let pp_typ ppf typ = Pprintast.core_type ppf (To_ocaml.of_typ typ)

let report_error ppf = function
  | Check_failed_aux (typ', constr_typ') ->
      pp_print_string ppf "Type error: Types '" ;
      pp_typ ppf typ' ;
      pp_print_string ppf "' and '" ;
      pp_typ ppf constr_typ' ;
      pp_print_string ppf "' are incompatable." ;
      pp_print_newline ppf ()
  | Check_failed (typ, constr_typ, typ', constr_typ') ->
      pp_print_string ppf "Type error: Cannot unify '" ;
      pp_typ ppf typ ;
      pp_print_string ppf "' and '" ;
      pp_typ ppf constr_typ ;
      pp_print_string ppf ", types '" ;
      pp_typ ppf typ' ;
      pp_print_string ppf "' and '" ;
      pp_typ ppf constr_typ' ;
      pp_print_string ppf "' are incompatable." ;
      pp_print_newline ppf ()
  | Unbound_constructor ctor ->
      fprintf ppf "Unbound constructor %s." ctor
  | Unbound_value value ->
      fprintf ppf "Unbound value %s." value
  | Unbound_record_field field ->
      fprintf ppf "Unbound record field %s." field
  | Empty_record ->
      fprintf ppf "Record has no fields."
  | Tdefer_found loc ->
      fprintf ppf "Internal error at %s: Unexpected Tdefer found." loc
  | Tpoly_found loc ->
      fprintf ppf "Internal error at %s: Unexpected Tpoly found." loc
  | Tvar_expected loc ->
      fprintf ppf "Internal error at %s: Expected a Tvar." loc

let () =
  Location.register_error_of_exn (function
    | Error (loc, err) -> Some (Location.error_of_printer loc report_error err)
    | _ -> None )