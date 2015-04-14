{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies, FlexibleContexts #-}
module Futhark.ExplicitAllocations
       ( explicitAllocations
       , simplifiable
       )
where

import Control.Applicative
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer
import Data.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS

import qualified Futhark.Representation.Basic as In
import Futhark.Optimise.Simplifier.Lore
  (Wise,
   mkWiseBody,
   mkWiseLetBinding,
   removeExpWisdom,
   removePatternWisdom)
import Futhark.MonadFreshNames
import Futhark.Representation.ExplicitMemory
import qualified Futhark.Representation.ExplicitMemory.IndexFunction.Unsafe as IxFun
import Futhark.Tools
import qualified Futhark.Analysis.SymbolTable as ST
import qualified Futhark.Analysis.ScalExp as SE
import Futhark.Optimise.Simplifier.Simplify (SimpleOps (..))
import qualified Futhark.Optimise.Simplifier.Engine as Engine

data Entry = Entry { entryMemSummary :: MemSummary
                   , entryType :: Type
                   }

type MemoryMap = HM.HashMap VName Entry

data AllocBinding = SizeComputation VName SE.ScalExp
                  | Allocation VName SubExp
                  | ArrayCopy VName Bindage VName
                    deriving (Eq, Ord, Show)

bindAllocBinding :: MonadBinder m => AllocBinding -> m ()
bindAllocBinding (SizeComputation name se) = do
  e <- SE.fromScalExp' se
  letBindNames'_ [name] e
bindAllocBinding (Allocation name size) =
  letBindNames'_ [name] $ PrimOp $ Alloc size
bindAllocBinding (ArrayCopy name bindage src) =
  letBindNames_ [(name,bindage)] $ PrimOp $ Copy $ Var src

class (MonadFreshNames m, HasTypeEnv m) => Allocator m where
  addAllocBinding :: AllocBinding -> m ()

  askMemoryMap :: m MemoryMap

  asksMemoryMap :: (MemoryMap -> a) -> m a
  asksMemoryMap f = f <$> askMemoryMap

allocateMemory :: Allocator m =>
                  String -> SubExp -> m VName
allocateMemory desc size = do
  v <- newVName desc
  addAllocBinding $ Allocation v size
  return v

computeSize :: Allocator m =>
               String -> SE.ScalExp -> m SubExp
computeSize desc se = do
  v <- newVName desc
  addAllocBinding $ SizeComputation v se
  return $ Var v

-- | Monad for adding allocations to an entire program.
newtype AllocM a = AllocM (BinderT ExplicitMemory
                           (ReaderT MemoryMap
                            (State VNameSource))
                           a)
                 deriving (Applicative, Functor, Monad,
                           MonadReader MemoryMap,
                           MonadFreshNames)

instance MonadBinder AllocM where
  type Lore AllocM = ExplicitMemory

  mkLetM pat e = return $ Let pat () e

  mkLetNamesM names e = do
    memoryMap <- ask
    types <- askTypeEnv
    pat <- patternWithAllocations memoryMap types names e
    return $ Let pat () e

  mkBodyM bnds res = return $ Body () bnds res

  addBinding =
    AllocM . addBinderBinding
  collectBindings (AllocM m) =
    AllocM $ collectBinderBindings m

instance HasTypeEnv AllocM where
  askTypeEnv = liftM2 HM.union (AllocM askTypeEnv) (HM.map entryType <$> ask)

instance Allocator AllocM where
  askMemoryMap = ask

  addAllocBinding (SizeComputation name se) =
    letBindNames'_ [name] =<< SE.fromScalExp' se
  addAllocBinding (Allocation name size) =
    letBindNames'_ [name] $ PrimOp $ Alloc size
  addAllocBinding (ArrayCopy name bindage src) =
    letBindNames_ [(name, bindage)] $ PrimOp $ SubExp $ Var src

runAllocM :: MonadFreshNames m => AllocM a -> m a
runAllocM = runAllocMWithEnv HM.empty

runAllocMWithEnv :: MonadFreshNames m =>
                    MemoryMap
                 -> AllocM a
                 -> m a
runAllocMWithEnv env (AllocM m) =
  fst <$> modifyNameSource (runState (runReaderT (runBinderT m mempty) env))

-- | Monad for adding allocations to a single pattern.
newtype PatAllocM a = PatAllocM (WriterT [AllocBinding]
                                 (ReaderT (MemoryMap, TypeEnv)
                                  (State VNameSource))
                                 a)
                    deriving (Applicative, Functor, Monad,
                              MonadReader (MemoryMap, TypeEnv),
                              MonadWriter [AllocBinding],
                              MonadFreshNames)

instance Allocator PatAllocM where
  askMemoryMap = fst <$> ask

  addAllocBinding = tell . pure

instance HasTypeEnv PatAllocM where
  askTypeEnv = do
    (memoryMap, types) <- ask
    return $ HM.map entryType memoryMap <> types

runPatAllocM :: MonadFreshNames m =>
                PatAllocM a -> MemoryMap -> TypeEnv -> m (a, [AllocBinding])
runPatAllocM (PatAllocM m) memoryMap types =
  modifyNameSource $ runState $ runReaderT (runWriterT m) (memoryMap, types)

allocForArray :: Allocator m =>
                 Type -> m (SubExp, VName)
allocForArray t = do
  size <-
    computeSize "bytes" $
    SE.sproduct $
    (SE.Val $ IntVal $ basicSize $ elemType t) :
    map SE.subExpToScalExp (arrayDims t)
  m <- allocateMemory "mem" size
  return (size, m)

allocsForBinding :: Allocator m =>
                    [Ident] -> [(Ident,Bindage)] -> Exp
                 -> m (Binding, [AllocBinding])
allocsForBinding sizeidents validents e = do
  rts <- expReturns lookupSummary' e
  types <- askTypeEnv
  memoryMap <- askMemoryMap
  ((patElems, postbnds),prebnds) <-
    runPatAllocM (allocsForPattern sizeidents validents rts) memoryMap types
  mapM_ addAllocBinding prebnds
  return (Let (Pattern patElems) () e,
          postbnds)

patternWithAllocations :: MonadBinder m =>
                          MemoryMap -> TypeEnv -> [(VName, Bindage)] -> Exp
                       -> m Pattern
patternWithAllocations memoryMap types names e = do
  (patElems,prebnds) <- runPatAllocM m memoryMap types
  mapM_ bindAllocBinding prebnds
  return $ Pattern patElems
  where m = do
          (ts',sizes) <- instantiateShapes' =<< expExtType e
          let identForBindage name t BindVar =
                pure (Ident name t, BindVar)
              identForBindage name _ bindage@(BindInPlace _ src _) = do
                t <- lookupType src
                pure (Ident name t, bindage)
          vals <- sequence [ identForBindage name t bindage  |
                             ((name,bindage), t) <- zip names ts' ]
          (Let (Pattern patElems) _ _, extrabnds) <- allocsForBinding sizes vals e
          case extrabnds of
            [] -> return patElems
            _  -> fail $ "Cannot make allocations for pattern of " ++ pretty e

allocsForPattern :: [Ident] -> [(Ident,Bindage)] -> [ExpReturns]
                 -> PatAllocM ([PatElem], [AllocBinding])
allocsForPattern sizeidents validents rts = do
  let sizes' = [ PatElem size BindVar Scalar | size <- sizeidents ]
  (vals,(memsizes, mems, postbnds)) <-
    runWriterT $ forM (zip validents rts) $ \((ident,bindage), rt) ->
    case rt of
      ReturnsScalar _ -> do
        summary <- lift $ summaryForBindage (identType ident) bindage
        return $ PatElem ident bindage summary

      ReturnsMemory _ ->
        return $ PatElem ident bindage Scalar

      ReturnsArray _ _ u (Just (ReturnsInBlock mem ixfun)) ->
        case bindage of
          BindVar ->
            return $ PatElem ident bindage $ MemSummary mem ixfun
          BindInPlace _ src is -> do
            (destmem,destixfun) <- lift $ lookupArraySummary' src
            if destmem == mem && destixfun == ixfun then
              return $ PatElem ident bindage $ MemSummary mem ixfun
              else do
              -- The expression returns in some memory, but we want to
              -- put the result somewhere else.  This means we need to
              -- store it in the memory it wants to first, then copy
              -- it to our intended destination in an extra binding.
              tmp_buffer <- lift $
                            newIdent (baseString (identName ident)<>"_buffer")
                            (stripArray (length is) $ identType ident
                             `setUniqueness` u)
              tell ([], [],
                    [ArrayCopy (identName ident) bindage $
                     identName tmp_buffer])
              return $ PatElem tmp_buffer BindVar $
                MemSummary mem ixfun

      ReturnsArray _ extshape _ Nothing
        | Just _ <- knownShape extshape -> do
          summary <- lift $ summaryForBindage (identType ident) bindage
          return $ PatElem ident bindage summary

      _ -> do
        (memsize,mem,(ident',lore)) <- lift $ memForBindee ident
        tell ([PatElem memsize BindVar Scalar],
              [PatElem mem     BindVar Scalar],
              [])
        return $ PatElem ident' bindage lore
  return (memsizes <> mems <> sizes' <> vals,
          postbnds)
  where knownShape = mapM known . extShapeDims
        known (Free v) = Just v
        known (Ext {}) = Nothing

summaryForBindage :: Allocator m =>
                     Type -> Bindage
                  -> m MemSummary
summaryForBindage t BindVar
  | basicType t =
    return Scalar
  | otherwise = do
    (_, m) <- allocForArray t
    return $ directIndexFunction m t
summaryForBindage _ (BindInPlace _ src _) =
  lookupSummary' src

memForBindee :: (MonadFreshNames m) =>
                Ident
             -> m (Ident,
                   Ident,
                   (Ident, MemSummary))
memForBindee ident = do
  size <- newIdent (memname <> "_size") (Basic Int)
  mem <- newIdent memname $ Mem $ Var $ identName size
  return (size,
          mem,
          (ident, directIndexFunction (identName mem) t))
  where  memname = baseString (identName ident) <> "_mem"
         t       = identType ident

directIndexFunction :: VName -> Type -> MemSummary
directIndexFunction mem t =
  MemSummary mem $ IxFun.iota $ arrayDims t

lookupSummary :: VName -> AllocM (Maybe MemSummary)
lookupSummary name = asks $ fmap entryMemSummary . HM.lookup name

lookupSummary' :: Allocator m =>
                  VName -> m MemSummary
lookupSummary' name = do
  res <- asksMemoryMap $ fmap entryMemSummary . HM.lookup name
  case res of
    Just summary -> return summary
    Nothing ->
      fail $ "No memory summary for variable " ++ pretty name

lookupArraySummary' :: Allocator m => VName -> m (VName, IxFun.IxFun)
lookupArraySummary' name = do
  summary <- lookupSummary' name
  case summary of MemSummary mem ixfun ->
                    return (mem, ixfun)
                  Scalar ->
                    fail $ "Variable " ++ pretty name ++ " does not look like an array."

bindeeSummary :: PatElem -> (VName, Entry)
bindeeSummary bindee = (patElemName bindee,
                        Entry (patElemLore bindee) (patElemType bindee))

bindeesSummary :: [PatElem] -> MemoryMap
bindeesSummary = HM.fromList . map bindeeSummary

fparamsSummary :: [FParam] -> MemoryMap
fparamsSummary = HM.fromList . map fparamSummary
  where fparamSummary fparam = (fparamName fparam,
                                Entry (fparamLore fparam) (fparamType fparam))

allocInFParams :: [In.FParam] -> ([FParam] -> AllocM a)
               -> AllocM a
allocInFParams params m = do
  (valparams, (memsizeparams, memparams)) <- runWriterT $ forM params $ \param ->
    case fparamType param of
      Array {} -> do
        (memsize,mem,(param',paramlore)) <- lift $ memForBindee $ fparamIdent param
        tell ([FParam memsize Scalar], [FParam mem Scalar])
        return $ FParam param' paramlore
      _ -> return param { fparamLore = Scalar }
  let summary = fparamsSummary valparams
      params' = memsizeparams <> memparams <> valparams
  local (summary `HM.union`) $ m params'

isArray :: SubExp -> AllocM Bool
isArray (Var v) = not <$> (==Scalar) <$> lookupSummary' v
isArray (Constant _) = return False

ensureDirectArray :: VName -> AllocM (SubExp, VName, SubExp)
ensureDirectArray v = do
  res <- lookupSummary v
  t <- lookupType v
  case (res, t) of
    (Just (MemSummary mem ixfun), Mem size)
      | IxFun.isDirect ixfun ->
        return (size, mem, Var v)
    _ ->
      -- We need to do a new allocation, copy 'v', and make a new
      -- binding for the size of the memory block.
      allocLinearArray (baseString v) $ Var v

allocLinearArray :: String
                 -> SubExp -> AllocM (SubExp, VName, SubExp)
allocLinearArray s se = do
  t <- subExpType se
  (size, mem) <- allocForArray t
  v' <- newIdent s t
  let pat = Pattern [PatElem v' BindVar $ directIndexFunction mem t]
  addBinding $ Let pat () $ PrimOp $ Copy se
  return (size, mem, Var $ identName v')

funcallArgs :: [(SubExp,Diet)] -> AllocM [(SubExp,Diet)]
funcallArgs args = do
  (valargs, (memsizeargs, memargs)) <- runWriterT $ forM args $ \(arg,d) -> do
    array <- lift $ isArray arg
    case (arg, array) of
      (Var v, True) -> do
        (size, mem, arg') <- lift $ ensureDirectArray v
        tell ([(size, Observe)], [(Var mem, Observe)])
        return (arg', d)
      _ ->
        return (arg, d)
  return $ memsizeargs <> memargs <> valargs

explicitAllocations :: In.Prog -> Prog
explicitAllocations prog =
  Prog $ evalState (mapM allocInFun $ In.progFunctions prog) free
  where free = newNameSourceForProg prog

memoryInRetType :: In.RetType -> RetType
memoryInRetType (ExtRetType ts) =
  evalState (mapM addAttr ts) $ startOfFreeIDRange ts
  where addAttr (Basic t) = return $ ReturnsScalar t
        addAttr (Mem _)  = fail "memoryInRetType: too much memory"
        addAttr (Array bt shape u) = do
          i <- get
          put $ i + 1
          return $ ReturnsArray bt shape u $ ReturnsNewBlock i

startOfFreeIDRange :: [ExtType] -> Int
startOfFreeIDRange = (1+) . HS.foldl' max 0 . shapeContext

allocInFun :: MonadFreshNames m => In.FunDec -> m FunDec
allocInFun (In.FunDec fname rettype params body) =
  runAllocM $ allocInFParams params $ \params' -> do
    body' <- insertBindingsM $ allocInBody body
    return $ FunDec fname (memoryInRetType rettype) params' body'

allocInBody :: In.Body -> AllocM Body
allocInBody (Body _ bnds res) =
  allocInBindings bnds $ \bnds' -> do
    (ses, allocs) <- collectBindings $ mapM ensureDirect $ resultSubExps res
    return $ Body () (bnds'<>allocs) res { resultSubExps = ses }
  where ensureDirect se@(Constant {}) = return se
        ensureDirect (Var v) = do
          bt <- basicType <$> lookupType v
          if bt
            then return $ Var v
            else do (_, _, v') <- ensureDirectArray v
                    return v'

allocInBindings :: [In.Binding] -> ([Binding] -> AllocM a)
                -> AllocM a
allocInBindings origbnds m = allocInBindings' origbnds []
  where allocInBindings' [] bnds' =
          m bnds'
        allocInBindings' (x:xs) bnds' = do
          allocbnds <- allocInBinding' x
          let summaries =
                bindeesSummary $
                concatMap (patternElements . bindingPattern) allocbnds
          local (`HM.union` summaries) $
            allocInBindings' xs (bnds'++allocbnds)
        allocInBinding' bnd = do
          ((),bnds') <- collectBindings $ allocInBinding bnd
          return bnds'

allocInBinding :: In.Binding -> AllocM ()
allocInBinding (Let pat _ e) = do
  e' <- allocInExp e
  let (sizeidents, validents) =
        splitAt (patternSize pat - expExtTypeSize e') $
        patternElements pat
      sizeidents' = map patElemIdent sizeidents
      validents' = [ (ident, bindage) | PatElem ident bindage () <- validents ]
  (bnd, bnds) <- allocsForBinding sizeidents' validents' e'
  addBinding bnd
  mapM_ bindAllocBinding bnds

funcallSubExps :: [SubExp] -> AllocM [SubExp]
funcallSubExps ses = map fst <$>
                     funcallArgs [ (se, Observe) | se <- ses ]

allocInExp :: In.Exp -> AllocM Exp
allocInExp (LoopOp (DoLoop res merge form
                    (Body () bodybnds bodyres))) =
  allocInFParams mergeparams $ \mergeparams' ->
  formBinds form $ do
    mergeinit' <- funcallSubExps mergeinit
    body' <- insertBindingsM $ allocInBindings bodybnds $ \bodybnds' -> do
      (ses,retbnds) <- collectBindings $
                       funcallSubExps $ resultSubExps bodyres
      let res' = bodyres { resultSubExps = ses }
      return $ Body () (bodybnds'<>retbnds) res'
    return $ LoopOp $
      DoLoop res (zip mergeparams' mergeinit') form body'
  where (mergeparams, mergeinit) = unzip merge
        formBinds (ForLoop i _) =
          local (HM.singleton i (Entry Scalar $ Basic Int)<>)
        formBinds (WhileLoop _) =
          id
allocInExp (LoopOp (Map {})) =
  fail "Cannot put explicit allocations in map yet."
allocInExp (LoopOp (Reduce {})) =
  fail "Cannot put explicit allocations in reduce yet."
allocInExp (LoopOp (Scan {})) =
  fail "Cannot put explicit allocations in scan yet."
allocInExp (LoopOp (Redomap {})) =
  fail "Cannot put explicit allocations in redomap yet."
allocInExp (Apply fname args rettype) = do
  args' <- funcallArgs args
  return $ Apply fname args' (memoryInRetType rettype)
allocInExp e = mapExpM alloc e
  where alloc =
          identityMapper { mapOnBody = allocInBody
                         , mapOnLambda = allocInLambda
                         , mapOnExtLambda = allocInExtLambda
                         , mapOnRetType = return . memoryInRetType
                         , mapOnFParam = fail "Unhandled fparam in ExplicitAllocations"
                         }

allocInLambda :: In.Lambda -> AllocM Lambda
allocInLambda lam = do
  body <- allocInBody $ lambdaBody lam
  return $ lam { lambdaBody = body }

allocInExtLambda :: In.ExtLambda -> AllocM ExtLambda
allocInExtLambda lam = do
  body <- allocInBody $ extLambdaBody lam
  return $ lam { extLambdaBody = body }

vtableToAllocEnv :: ST.SymbolTable (Wise ExplicitMemory)
                 -> MemoryMap
vtableToAllocEnv = HM.fromList . mapMaybe entryToMemSummary .
                   HM.toList . ST.bindings
  where entryToMemSummary (k,entry) = do
          summary <- (snd <$> ST.entryLetBoundLore entry) <|>
                     ST.entryFParamLore entry
          return (k, Entry summary $ ST.entryType entry)

simplifiable :: (Engine.MonadEngine m,
                 Engine.InnerLore m ~ ExplicitMemory) =>
                SimpleOps m
simplifiable =
  SimpleOps mkLetS' mkBodyS' mkLetNamesS'
  simplifyMemSummary simplifyMemSummary
  simplifyRetType'
  where mkLetS' _ pat e =
          return $ mkWiseLetBinding (removePatternWisdom pat) () e

        mkBodyS' _ bnds res = return $ mkWiseBody () bnds res

        mkLetNamesS' vtable names e = do
          pat' <- patternWithAllocations env types names $
                  removeExpWisdom e
          return $ mkWiseLetBinding pat' () e
          where env = vtableToAllocEnv vtable
                types = ST.typeEnv vtable

        simplifyMemSummary Scalar =
          return Scalar
        simplifyMemSummary (MemSummary ident ixfun) =
          MemSummary <$> Engine.simplifyVName ident <*> pure ixfun

        simplifyRetType' = mapM simplifyReturns
          where simplifyReturns (ReturnsScalar bt) =
                  return $ ReturnsScalar bt
                simplifyReturns (ReturnsArray bt shape u ret) =
                  ReturnsArray bt <$>
                  Engine.simplifyExtShape shape <*>
                  pure u <*>
                  simplifyMemReturn ret
                simplifyReturns (ReturnsMemory size) =
                  ReturnsMemory <$> Engine.simplifySubExp size
                simplifyMemReturn (ReturnsNewBlock i) =
                  return $ ReturnsNewBlock i
                simplifyMemReturn (ReturnsInBlock v ixfun) =
                  ReturnsInBlock <$> Engine.simplifyVName v <*>
                  pure ixfun
