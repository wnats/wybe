--  File     : Normalise.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri Jan  6 11:28:23 2012
--  Purpose  : Convert parse tree into AST
--  Copyright: � 2012 Peter Schachte.  All rights reserved.

module Normalise (normalise) where

import AST
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Text.ParserCombinators.Parsec.Pos

normalise :: [Item] -> Compiler ()
normalise items = do
    mapM_ normaliseItem items

normaliseItem :: Item -> Compiler ()
normaliseItem (TypeDecl vis (TypeProto name params) items pos) = do
    fname <- getDirectory
    compileSubmodule fname name (Just params) pos vis (normalise items)
normaliseItem (ModuleDecl vis name items pos) = do
    fname <- getDirectory
    compileSubmodule fname name Nothing pos vis (normalise items)
normaliseItem (ImportMods vis imp modspecs pos) = do
    mapM_ (\spec -> addImport spec imp Nothing vis) modspecs
normaliseItem (ImportItems vis imp modspec imports pos) = do
    addImport modspec imp (Just imports) vis


normaliseItem (ResourceDecl vis name typ pos) =
  addResource name (SimpleResource typ pos) vis
normaliseItem (FuncDecl vis (FnProto name params) resulttype result pos) =
  normaliseItem $
  ProcDecl 
  vis
  (ProcProto name $ params ++ [Param "$" resulttype ParamOut])
  [Unplaced $
   ProcCall "=" [Unplaced $ Var "$" ParamOut, result]]
  pos
normaliseItem (ProcDecl vis proto@(ProcProto name params) stmts pos) = do
  stmts' <- normaliseStmts stmts
  addProc name proto stmts' pos vis
normaliseItem (CtorDecl vis proto pos) = do
    modname <- getModuleName
    Just modparams <- getModuleParams
    addCtor modname modparams proto
normaliseItem (StmtDecl stmt pos) = do
  stmts <- normaliseStmt stmt pos
  oldproc <- lookupProc ""
  case oldproc of
    Nothing -> 
      addProc "" (ProcProto "" []) stmts Nothing Private
    Just [ProcDef id proto stmts' pos'] ->
      replaceProc "" id proto (stmts' ++ stmts) pos' Private


addCtor :: Ident -> [Ident] -> FnProto -> Compiler ()
addCtor typeName typeParams (FnProto ctorName params) = do
    let typespec = TypeSpec typeName $ List.map (\n->TypeSpec n []) typeParams
    normaliseItem (FuncDecl Public (FnProto ctorName params)
                   typespec
                   (List.foldr
                    (\(Param var _ dir) struct ->
                      (Unplaced $ Fncall 
                       ("update$"++var) 
                       [Unplaced $ Var var dir,struct]))
                    (Unplaced $ Fncall "$alloc" [Unplaced $ 
                                                 Var ctorName ParamIn])
                    $ List.reverse params) 
                   Nothing)
    mapM_ (addGetterSetter typespec ctorName) params

addGetterSetter :: TypeSpec -> Ident -> Param -> Compiler ()
addGetterSetter rectype ctorName (Param field fieldtype _) = do
    addProc field 
      (ProcProto field [Param "$rec" rectype ParamIn,
                        Param "$field" fieldtype ParamOut])
      [Unplaced $ PrimForeign "" "access" Nothing [ArgVar ctorName ParamIn,
                                                   ArgVar "$rec" ParamIn,
                                                   ArgVar "$field" ParamOut]]
      Nothing Public
    addProc field 
      (ProcProto field [Param "$rec" rectype ParamInOut,
                        Param "$field" fieldtype ParamIn])
      [Unplaced $ PrimForeign "" "mutate" Nothing [ArgVar ctorName ParamIn,
                                                   ArgVar "$rec" ParamInOut,
                                                   ArgVar "$field" ParamIn]]
      Nothing Public

normaliseStmts :: [Placed Stmt] -> Compiler [Placed Prim]
normaliseStmts [] = return []
normaliseStmts (stmt:stmts) = do
  front <- case stmt of
    Placed stmt' pos -> normaliseStmt stmt' $ Just pos
    Unplaced stmt'   -> normaliseStmt stmt' Nothing
  back <- normaliseStmts stmts
  return $ front ++ back

normaliseStmt :: Stmt -> Maybe SourcePos -> Compiler [Placed Prim]
normaliseStmt (ProcCall name args) pos = do
  (args',pre,post) <- normaliseArgs args
  return $ pre ++ maybePlace (PrimCall name Nothing args') pos:post
normaliseStmt (ForeignCall lang name args) pos = do
  (args',pre,post) <- normaliseArgs args
  return $ pre ++ maybePlace (PrimForeign lang name Nothing args') pos:post
normaliseStmt (Cond exp thn els) pos = do
  (exp',condstmts) <- normaliseOuterExp exp
  thn' <- normaliseStmts thn
  els' <- normaliseStmts els
  stmts <- makeCond exp' [thn',els'] pos
  return $ condstmts ++ stmts
normaliseStmt (Loop loop) pos = do
  (init,body,update) <- normaliseLoopStmts loop
  return $ init ++ [maybePlace (PrimLoop $ body++update) pos]
normaliseStmt Nop pos = do
  return $ []

normaliseLoopStmts :: [Placed LoopStmt] -> 
                      Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseLoopStmts [] = return ([],[],[])
normaliseLoopStmts (stmt:stmts) = do
  (backinit,backbody,backupdate) <- normaliseLoopStmts stmts
  (frontinit,frontbody,frontupdate) <- case stmt of
    Placed stmt' pos -> normaliseLoopStmt stmt' $ Just pos
    Unplaced stmt'   -> normaliseLoopStmt stmt' Nothing
  return $ (frontinit ++ backinit, 
            frontbody ++ backbody,
            frontupdate ++ backupdate)

normaliseLoopStmt :: LoopStmt -> Maybe SourcePos -> 
                     Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseLoopStmt (For gen) pos = normaliseGenerator gen pos
normaliseLoopStmt (BreakIf exp) pos = do
  (exp',stmts) <- normaliseOuterExp exp
  cond <- freshVar
  return $ ([],stmts ++ [assign cond exp',maybePlace (PrimBreakIf cond) pos],[])
normaliseLoopStmt (NextIf exp) pos = do
  (exp',stmts) <- normaliseOuterExp exp
  cond <- freshVar
  return ([],stmts ++ [assign cond exp',maybePlace (PrimNextIf cond) pos],[])
normaliseLoopStmt (NormalStmt stmt) pos = do
  stmts <- normaliseStmt (content stmt) pos
  return ([],stmts,[])


normaliseGenerator :: Generator -> Maybe SourcePos ->
                      Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseGenerator (In var exp) pos = do
  (arg,init) <- normaliseOuterExp exp
  stateVar <- freshVar
  testVar <- freshVar
  let update = procCall "next" [ArgVar stateVar ParamInOut,
                                ArgVar var ParamInOut,
                                ArgVar testVar ParamOut]
  return (init++[assign stateVar arg,update],
          [update],[Unplaced $ PrimBreakIf testVar])
normaliseGenerator (InRange var exp updateOp inc limit) pos = do
  (arg,init1) <- normaliseOuterExp exp
  (incArg,init2) <- normaliseOuterExp inc
  let update = [procCall updateOp 
                [ArgVar var ParamIn,incArg,ArgVar var ParamOut]]
  (init,test) <- case limit of
    Nothing -> return (init1++init2,[])
    Just (comp,limit') -> do
      testVar <- freshVar
      (limitArg,init3) <- normaliseOuterExp limit'
      return (init1++init2++init3,
              [procCall comp [ArgVar var ParamIn,limitArg,
                              ArgVar testVar ParamOut],
               Unplaced $ PrimBreakIf testVar])
  return (init++[assign var arg],test,update)


normaliseArgs :: [Placed Exp] -> Compiler ([PrimArg],[Placed Prim],[Placed Prim])
normaliseArgs [] = return ([],[],[])
normaliseArgs (pexp:args) = do
  let pos = place pexp
  (arg,_,pre,post) <- normaliseExp (content pexp) (place pexp) ParamIn
  (args',pres,posts) <- normaliseArgs args
  return (arg:args', pre ++ pres, post ++ posts)


normaliseOuterExp :: Placed Exp -> Compiler (PrimArg,[Placed Prim])
normaliseOuterExp exp = do
    (arg,_,pre,post) <- normaliseExp (content exp) (place exp) ParamIn
    return (arg,pre++post)


normaliseExp :: Exp -> Maybe SourcePos -> FlowDirection ->
                 Compiler (PrimArg,FlowDirection,[Placed Prim],[Placed Prim])
normaliseExp (IntValue a) pos dir = do
  mustBeIn dir pos
  return (ArgInt a, ParamIn, [], [])
normaliseExp (FloatValue a) pos dir = do
  mustBeIn dir pos
  return (ArgFloat a, ParamIn, [], [])
normaliseExp (StringValue a) pos dir = do
  mustBeIn dir pos
  return (ArgString a, ParamIn, [], [])
normaliseExp (CharValue a) pos dir = do
  mustBeIn dir pos
  return (ArgChar a, ParamIn, [], [])
normaliseExp (Var name dir) pos _ = do
  return (ArgVar name dir, dir, [], [])
normaliseExp (Where stmts exp) pos dir = do
  mustBeIn dir pos
  stmts1 <- normaliseStmts stmts
  (exp',stmts2) <- normaliseOuterExp exp
  return (exp', ParamIn, stmts1++stmts2, [])
normaliseExp (CondExp cond thn els) pos dir = do
  mustBeIn dir pos
  (cond',stmtscond) <- normaliseOuterExp cond
  (thn',stmtsthn) <- normaliseOuterExp thn
  (els',stmtsels) <- normaliseOuterExp els
  result <- freshVar
  prims <- makeCond cond' 
           [stmtsthn++[assign result thn'], stmtsels++[assign result els']]
           pos
  return (ArgVar result ParamIn, ParamIn, stmtscond++prims, [])
normaliseExp (Fncall name exps) pos dir = do
  mustBeIn dir pos
  (exps',dir',pre,post) <- normalisePlacedExps exps
  let inexps = List.map argAsInput exps'
  result <- freshVar
  let dir'' = dir `flowJoin` dir'
  let pre' = if flowsIn dir'' then
                 pre ++ [maybePlace (PrimCall name Nothing 
                                     (inexps++[ArgVar result ParamOut])) 
                         pos]
             else pre
  let post' = if flowsOut dir'' then
                  maybePlace 
                  (PrimCall name Nothing (exps'++[ArgVar result ParamIn]))
                  pos:post
              else post
  return (ArgVar result dir'', dir'', pre', post')
normaliseExp (ForeignFn lang name exps) pos dir = do
  mustBeIn dir pos
  (exps',_,pre,post) <- normalisePlacedExps exps
  result <- freshVar
  let pre' = pre ++ [maybePlace (PrimForeign lang name Nothing 
                                 (exps'++[ArgVar result ParamOut])) 
                     pos]
  return (ArgVar result ParamIn, ParamIn, pre', post)


mustBeIn :: FlowDirection -> Maybe SourcePos -> Compiler ()
mustBeIn NoFlow  _ = return ()
mustBeIn ParamIn _ = return ()
mustBeIn ParamOut pos = do
  errMsg "Flow error:  invalid output argument" pos
mustBeIn ParamInOut pos = do
  errMsg "Flow error:  invalid input/output argument" pos


flowsIn :: FlowDirection -> Bool
flowsIn NoFlow     = False
flowsIn ParamIn    = True
flowsIn ParamOut   = False
flowsIn ParamInOut = True

flowsOut :: FlowDirection -> Bool
flowsOut NoFlow     = False
flowsOut ParamIn = False
flowsOut ParamOut = True
flowsOut ParamInOut = True

argAsInput :: PrimArg -> PrimArg
argAsInput (ArgVar var _) = ArgVar var ParamIn
argAsInput other = other

assign :: VarName -> PrimArg -> Placed Prim
assign var val = procCall "=" [ArgVar var ParamOut, val]

procCall :: ProcName -> [PrimArg] -> Placed Prim
procCall proc args = Unplaced $ PrimCall proc Nothing args

makeCond :: PrimArg -> [[Placed Prim]] -> Maybe SourcePos -> 
            Compiler [Placed Prim]
makeCond cond branches pos = do
  case cond of
    ArgVar name ParamIn -> do
      result <- freshVar
      return [maybePlace (PrimCond name branches) pos]
    ArgInt n ->
      if n >= 0 && n <= fromIntegral (length branches) then
        return $ branches !! (fromInteger n)
      else
        return $ head branches
    _ -> do
      errMsg "Can't use a non-integer type as a Boolean" pos
      return $ head branches -- XXX has the right type, but probably not good


normalisePlacedExps :: [Placed Exp] -> 
                      Compiler ([PrimArg],FlowDirection,
                                [Placed Prim],[Placed Prim])
normalisePlacedExps [] = return ([],NoFlow,[],[])
normalisePlacedExps (exp:exps) = do
  (args',flow',pres,posts) <- normalisePlacedExps exps
  (exp',flow,pre,post) <- normaliseExp (content exp) (place exp) ParamIn
  return  (exp':args', flow `flowJoin` flow', pre ++ pres, post ++ posts)

-- Join on the lattice of flow directions
flowJoin :: FlowDirection -> FlowDirection -> FlowDirection
flowJoin NoFlow     x          = x
flowJoin x          NoFlow     = x
flowJoin ParamInOut _          = ParamInOut
flowJoin _          ParamInOut = ParamInOut
flowJoin ParamIn    ParamOut   = ParamInOut
flowJoin ParamIn    ParamIn    = ParamIn
flowJoin ParamOut   ParamOut   = ParamOut
flowJoin ParamOut   ParamIn    = ParamInOut
