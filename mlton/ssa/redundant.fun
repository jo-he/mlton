(* Copyright (C) 1997-1999 NEC Research Institute.
 * Please see the file LICENSE for license information.
 *)
functor Redundant (S: REDUNDANT_STRUCTS): REDUNDANT = 
struct

open S

type int = Int.t
type word = Word.t

structure Eqrel:>
   sig
      type t
	 
      val areEquivalent: t * int * int -> bool
      val classes: t -> int list list
      val equals: t * t -> bool
      val fixedPoint: unit -> unit
      val fromTypes: Type.t vector -> t
      val layout: t -> Layout.t
      val refine: t * (int * int -> bool) -> unit
      val unify: t * t -> unit
   end =
   struct
      structure R = EquivalenceRelation
      structure Set = DisjointSet

      datatype t = T of {me: R.t Set.t,
			 refinements: (int * int -> bool) list ref}

      val all: t list ref = ref []

      fun fromTypes ts =
	 let val er = T {me = Set.singleton (R.make (Vector.toList ts,
						     Type.equals)),
			 refinements = ref []}
	 in List.push (all, er); er
	 end

      fun me (T {me, ...}) = Set.value me

      fun areEquivalent (er, i, j) = R.areEquivalent (me er, i, j)

      val classes = R.classes o me

      fun equals (T {me, ...}, T {me = me', ...}) = Set.equals (me, me')

      val layout = R.layout o me

      fun refine (T {refinements, ...}, f) = List.push (refinements, f)

      (* Relies on the fact that all unifications happen before the fixed point.
       *)
      fun unify (T {me, ...}, T {me = me', ...}) = Set.union (me, me')

      fun fixedPoint () =
	 (FixedPoint.fix'
	  (fn continue =>
	   List.foreach (!all, fn T {me, refinements} =>
			 let val r = Set.value me
			    val r' = List.fold (!refinements, r,
						fn (refinement, r) =>
						R.refine (r, refinement))
			 in if R.equals (r, r')
			       then ()
			    else (continue (); Set.setValue (me, r'))
			 end))
	  ; all := [])
   end


open Exp Transfer

fun redundant (Program.T {datatypes, globals, functions, main}) =
   let
      val {get = funcInfo: Func.t -> {
				      arg: Eqrel.t,
				      return: Eqrel.t
				      },
	   set = setFuncInfo, ...} =
	 Property.getSetOnce
	 (Func.plist, Property.initRaise ("Redundant.info", Func.layout))
      val {get = labelInfo: Label.t -> Eqrel.t,
	   set = setLabelInfo, ...} =
	 Property.getSetOnce
	 (Label.plist, Property.initRaise ("Redundant.info", Label.layout))
      val {get = varInfo : Var.t -> {
				     index: int,
				     arg: Eqrel.t
				     } option,
	   set = setVarInfo, ...} =
	 Property.getSetOnce (Var.plist, Property.initConst NONE)
      fun varEquiv (x, y) =
	 Var.equals (x, y)
	 orelse (case (varInfo x, varInfo y) of
		    (SOME {index = i, arg = r},
		     SOME {index = i', arg = r'}) =>
		       Eqrel.equals (r, r') andalso Eqrel.areEquivalent (r, i, i')
		  | _ => false)
      (* compute the fixed point *)
      val _ =
	 let
	    fun makeFormalsRel (xs: (Var.t * Type.t) vector): Eqrel.t =
	       let
		  val eqrel = Eqrel.fromTypes (Vector.map (xs, #2))
	       in Vector.foreachi (xs, fn (i, (x, _)) =>
				   setVarInfo (x, SOME {index = i, arg = eqrel}))
		  ; eqrel
	       end
	    (* initialize all varInfo and funcInfo *)
	    val _ =
	       List.foreach
	       (functions, fn f =>
		let val {name, args, returns, ...} = Function.dest f
		in setFuncInfo (name, {
				       arg = makeFormalsRel args,
				       return = Eqrel.fromTypes returns
				       })
		end)

	    (* Add the calls to all the funcInfos *)
	    val _ =
	       List.foreach
	       (functions, fn f =>
		let 
		   val varEquiv =
		      fn vars => fn (i, j) => varEquiv (Vector.sub (vars, i),
							Vector.sub (vars, j))
		   val {name, blocks, ...} = Function.dest f
		   val {return, ...} = funcInfo name
		in 
		   Vector.foreach
		   (blocks, fn Block.T {label, args, ...} =>
		    setLabelInfo (label, (makeFormalsRel args))) ;
		   Vector.foreach
		   (blocks, fn Block.T {transfer, ...} =>
		    case transfer of
		       Call {func, args, return = ret, ...} =>
		          let
			     val {arg = arg', return = return'} = funcInfo func
			  in 
			     Eqrel.refine (arg', varEquiv args) 
			     ; Eqrel.unify (return',
					    case ret of
					       NONE => return
					     | SOME {cont, ...} => labelInfo cont)
			  end
		      | Case {cases = Cases.Con cases, ...} =>
			   (* For now, assume that constructor arguments
			    * are never redundant.  Thus all case branches
			    * need to have trivial equivalence relations.
			    *)
			   Vector.foreach (cases, fn (_, l) =>
					   Eqrel.refine (labelInfo l,
							 fn _ => false))
		      | Goto {dst, args, ...} =>
			   Eqrel.refine (labelInfo dst, varEquiv args)
		      | Return xs => Eqrel.refine (return, varEquiv xs)
		      | _ => ())
		end)
	    val _ = Eqrel.fixedPoint ()
	 in ()
	 end
      val _ = 
	 Control.diagnostics
	 (fn display =>
	  List.foreach
	  (functions, fn f => 
	   let open Layout
	       val {name, blocks, ...} = Function.dest f
	       val {arg, return} = funcInfo name
	   in display (seq [Func.layout name,
			    str "  ",
			    Eqrel.layout arg,
			    Eqrel.layout return]) ;
	      Vector.foreach
	      (blocks, fn Block.T {label, args, ...} =>
	       let val arg = labelInfo label
	       in display (seq [str "\t",
				Label.layout label,
				str " ",
				Eqrel.layout arg])
	       end)
	   end))
      val {get = replacement : Var.t -> Var.t option, set = setReplacement, ...} =
	 Property.getSetOnce (Var.plist, Property.initConst NONE)
      datatype red =
	 Useful
       | Redundant of int (* the index it is the same as *)

      (* Turn an equivalence relation on 0 ... n -1 into a list of length n,
       * by choosing a representative of each class.
       *)
      fun 'a makeReds (xs: 'a vector, r: Eqrel.t): red vector =
	 let
	    val classes = Eqrel.classes r
	    fun getRed i =
	       let
		  val rec loop =
		     fn [] => Useful
		      | class :: classes =>
			   case class of
			      [] => Error.bug "empty class"
			    | [_] => Error.bug "trivial class"
			    | j :: js =>
				 if i = j
				    then Useful
				 else if List.exists (js, fn j => i = j)
					 then Redundant j
				      else loop classes
	       in loop classes
	       end
	 in Vector.tabulate (Vector.length xs, getRed)
	 end
      fun redundantFormals (xs: (Var.t * Type.t) vector, r: Eqrel.t)
	 : red vector * (Var.t * Type.t) vector =
	 let
	    val reds = makeReds (xs, r)
	    val xs =
	       Vector.keepAllMap2
	       (xs, reds, fn (x, red) =>
		case red of
		   Useful => SOME x
		 | Redundant i =>
		      (setReplacement (#1 x, SOME (#1 (Vector.sub (xs, i))))
		       ; NONE))
	 in (reds, xs)
	 end
      fun keepUseful (reds: red vector, xs: 'a vector): 'a vector =
	 Vector.keepAllMap2 (reds, xs, fn (r, x) =>
			     case r of
				Useful => SOME x
			      | _ => NONE)
      val {get = funcReds : Func.t -> {argsRed: red vector,
				       args: (Var.t * Type.t) vector,
				       returnsRed: red vector,
				       returns: Type.t vector},
	   set = setFuncReds, ...} =
	 Property.getSetOnce (Func.plist,
			      Property.initRaise ("funcReds", Func.layout))
      val {get = labelReds: Label.t -> {argsRed: red vector,
					args: (Var.t * Type.t) vector},
	   set = setLabelReds, ...} =
	 Property.getSetOnce (Label.plist,
			      Property.initRaise ("labelReds", Label.layout))
      val _ =
	 List.foreach
	 (functions, fn f =>
	  let
	     val {name, args, blocks, returns, ...} = Function.dest f
	     val {arg, return} = funcInfo name
	     val returnsRed = makeReds (returns, return)
	     val returns = keepUseful (returnsRed, returns)
	     val (argsRed, args) = redundantFormals (args, arg)
	  in
	     setFuncReds (name, {args = args,
				 argsRed = argsRed,
				 returns = returns,
				 returnsRed = returnsRed}) ;
	     Vector.foreach
	     (blocks, fn Block.T {label, args, ...} =>
	      let
		 val (argsRed, args) = redundantFormals (args, labelInfo label)
	      in
		 setLabelReds (label, {args = args,
				       argsRed = argsRed})
	      end)
	  end)
      fun loopVar x =
	 case replacement x of
	    NONE => x
	  | SOME y => y
      fun loopVars xs = Vector.map (xs, loopVar)
      val functions =
	 List.map
	 (functions, fn f =>
	  let
	     val {name, args, start, blocks, returns} = Function.dest f
	     val {args, returns, returnsRed, ...} = funcReds name

	     val blocks =
	        Vector.map
		(blocks, fn Block.T {label, args, statements, transfer} =>
		 let
		    val {args, ...} = labelReds label

		    val statements =
		       Vector.map
		       (statements, fn Statement.T {var, ty, exp} =>
			Statement.T {var = var,
				     ty = ty,
				     exp = Exp.replaceVar (exp, loopVar)})

		    val transfer =
		       case transfer of
			  Bug => Bug
			| Call {func, args, return} =>
			     Call {func = func, 
				   args = loopVars (keepUseful 
						    (#argsRed (funcReds func),
						     args)),
				   return = return}
			| Case {test, cases, default} =>
			     Case {test = loopVar test, 
				   cases = cases,
				   default = default}
			| Goto {dst, args} =>
			     Goto {dst = dst,
				   args = loopVars (keepUseful 
						    (#argsRed (labelReds dst), 
						     args))}
			| Prim {prim, args, failure, success} =>
			     Prim {prim = prim,
				   args = loopVars args,
				   failure = failure,
				   success = success}
			| Raise x => Raise (loopVar x)
			| Return xs => Return (loopVars (keepUseful (returnsRed, xs)))

		 in
		    Block.T {label = label,
			     args = args,
			     statements = statements,
			     transfer = transfer}
		 end)

	  in
	     Function.new {name = name,
			   args = args,
			   start = start,
			   blocks = blocks,
			   returns = returns}
	  end)
      val p = Program.T {datatypes = datatypes,
			 globals = globals,
			 functions = functions,
			 main = main}
      val _ = Program.clear p
   in
      p
   end

end
