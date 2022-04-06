module Eclair.Lowering.EIR
  ( compileEIR
  ) where

import Protolude hiding (Type, and, void)
import Control.Arrow ((&&&))
import Data.Functor.Foldable hiding (fold)
import Data.ByteString.Short hiding (index)
import qualified Data.Text as T
import qualified Data.Map as M
import Data.List ((!!))
import Data.Maybe (fromJust)
import LLVM.AST (Module)
import LLVM.AST.Operand hiding (Metadata)
import LLVM.AST.Name
import LLVM.AST.Type
import LLVM.AST.Constant hiding (index)
import qualified LLVM.AST.IntegerPredicate as IP
import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Module
import LLVM.IRBuilder.Monad
import LLVM.IRBuilder.Combinators
import qualified Eclair.EIR.IR as EIR
import qualified Eclair.LLVM.BTree as BTree
import Eclair.LLVM.Metadata
import Eclair.LLVM.Codegen
import Eclair.RA.IndexSelection
import Eclair.Syntax


-- TODO: refactor this entire code, split functionality into multiple modules, ...

type EIR = EIR.EIR
type EIRF = EIR.EIRF
type Relation = EIR.Relation

type VarMap = Map Text Operand
type FunctionsMap = Map (Relation, Index) Functions

data Externals
  = Externals
  { extMalloc :: Operand
  , extFree :: Operand
  }

data LowerState
  = LowerState
  { programType :: Type
  , fnsMap :: FunctionsMap
  , varMap :: VarMap
  , externals :: Externals
  }

type CodegenM = ReaderT LowerState (IRBuilderT (ModuleBuilderT IO))

compileEIR :: EIR -> IO Module
compileEIR = \case
  EIR.Block (EIR.DeclareProgram metas : decls) -> buildModuleT "eclair_program" $ do
    mallocFn <- extern "malloc" [i32] (ptr i8)
    freeFn <- extern "free" [ptr i8] void
    let externalMap = Externals mallocFn freeFn
    fnss <- traverse (codegenRuntime . snd) metas
    let fnsInfo = zip (map (map getIndexFromMeta) metas) fnss
        fnsMap = M.fromList fnsInfo
    programTy <- mkType "program" fnss
    traverse_ (processDecl programTy fnsMap externalMap) decls
  _ ->
    panic "Unexpected top level EIR declarations when compiling to LLVM!"
  where
    processDecl programTy fnsMap externalMap = \case
      EIR.Function name tys retTy body -> do
        let beginState = LowerState programTy fnsMap mempty externalMap
            unusedRelation = panic "Unexpected use of relation for function type when lowering EIR to LLVM."
            unusedIndex = panic "Unexpected use of index for function type when lowering EIR to LLVM."
            getType ty = runReaderT (toLLVMType unusedRelation unusedIndex ty) beginState
        argTypes <- liftIO $ traverse getType tys
        returnType <- liftIO $ getType retTy
        let args = zipWith mkArg [0..] argTypes
        function (mkName $ T.unpack name) args returnType $ \args -> do
          runReaderT (fnBodyToLLVM args body) beginState
      _ ->
        panic "Unexpected top level EIR declaration when compiling to LLVM!"

-- NOTE: zygo is kind of abused here, since due to lazyness we can choose what we need
-- to  compile to LLVM: instructions either return "()" or an "Operand".
fnBodyToLLVM :: [Operand] -> EIR -> CodegenM ()
fnBodyToLLVM args = zygo instrToOperand instrToUnit
  where
    instrToOperand :: EIRF (CodegenM Operand) -> CodegenM Operand
    instrToOperand = \case
      EIR.FunctionArgF pos ->
        pure $ args !! pos
      EIR.FieldAccessF structOrVar pos -> do
        -- NOTE: structOrVar is always a pointer to a heap-/stack-allocated
        -- value so we need to first deref the pointer, and then index into the
        -- fields of the value ('addr' does this for us).
        addr (mkPath [int32 $ toInteger pos]) =<< structOrVar
      EIR.VarF v ->
        -- TODO: can we use `named` here? will it update everywhere?
        -- TODO: where do we put a value in the map? do we need "para" effect also?
        asks (fromJust . M.lookup v . varMap)
      EIR.NotF bool ->
        not' =<< bool
      EIR.AndF bool1 bool2 -> do
        b1 <- bool1
        b2 <- bool2
        and b1 b2
      EIR.EqualsF lhs rhs -> do
        a <- lhs
        b <- rhs
        icmp IP.EQ a b
      EIR.CallF r idx fn args ->
        doCall r idx fn args
      EIR.HeapAllocateProgramF -> do
        (malloc, programTy) <- asks (extMalloc . externals &&& programType)
        let programSize = ConstantOperand $ sizeof programTy
        pointer <- call malloc [(programSize, [])]
        pointer `bitcast` ptr programTy
      EIR.StackAllocateF r idx ty -> do
        theType <- toLLVMType r idx ty
        alloca theType (Just (int32 1)) 0
      EIR.LitF value ->
        pure $ int32 (fromIntegral value)
      _ ->
        panic "Unhandled pattern match case in 'instrToOperand' while lowering EIR to LLVM!"
    instrToUnit :: EIRF (CodegenM Operand, CodegenM ()) -> CodegenM ()
    instrToUnit = \case
      EIR.BlockF stmts ->
        traverse_ snd stmts
      EIR.ParF stmts ->
        -- NOTE: this is just sequential evaluation for now
        traverse_ snd stmts
      EIR.AssignF (fst -> operand) (fst -> val) -> do
        -- TODO use `named` combinator, store var in varMap
        -- TODO: what if we are assigning to field in struct? inspect var result?
        address <- operand
        value <- val
        store value 0 address
      EIR.FreeProgramF (fst -> programVar) -> do
        freeFn <- asks (extFree . externals)
        program <- programVar
        () <$ call freeFn [(program, [])]
      EIR.CallF r idx fn (map fst -> args) ->
        () <$ doCall r idx fn args
      EIR.LoopF stmts ->
        loop $ traverse_ snd stmts
      EIR.IfF (fst -> cond) (snd -> body) -> do
        condition <- cond
        if' condition body
      EIR.JumpF lbl ->
        br (labelToName lbl)
      EIR.LabelF lbl ->
        -- NOTE: the label should be globally unique thanks to the RA -> EIR lowering pass
        emitBlockStart $ labelToName lbl
      EIR.ReturnF (fst -> value) ->
        ret =<< value
      _ ->
        panic "Unhandled pattern match case in 'instrToUnit' while lowering EIR to LLVM!"
    doCall :: Relation -> Index -> EIR.Function -> [CodegenM Operand] -> CodegenM Operand
    doCall r idx fn args = do
      argOperands <- sequence args
      func <- lookupFunction r idx fn
      call func $ (, []) <$> argOperands

-- TODO: use caching, return cached compilation?
codegenRuntime :: Metadata -> ModuleBuilderT IO Functions
codegenRuntime = \case
  BTree meta -> BTree.codegen meta

lookupFunction :: Relation -> Index -> EIR.Function -> CodegenM Operand
lookupFunction r idx fn =
  extractFn . fromJust . M.lookup (r, idx) <$> asks fnsMap
  where
    extractFn = case fn of
      EIR.InitializeEmpty -> fnInitEmpty
      EIR.Destroy -> fnDestroy
      EIR.Purge -> fnPurge
      EIR.Swap -> fnSwap
      EIR.InsertRange -> fnInsertRange
      EIR.IsEmpty -> fnIsEmpty
      EIR.Contains -> fnContains
      EIR.Insert -> fnInsert
      EIR.IterCurrent -> fnIterCurrent
      EIR.IterNext -> fnIterNext
      EIR.IterIsEqual -> fnIterIsEqual
      EIR.IterLowerBound -> fnLowerBound
      EIR.IterUpperBound -> fnUpperBound
      EIR.IterBegin -> fnBegin
      EIR.IterEnd -> fnEnd

-- TODO: add hash?
mkType :: Name -> [Functions] -> ModuleBuilderT IO Type
mkType name fnss =
  typedef name (struct tys)
  where
    struct = Just . StructureType False
    tys = map typeObj fnss

labelToName :: EIR.LabelId -> Name
labelToName (EIR.LabelId lbl) =
  mkName $ T.unpack lbl

toLLVMType :: (MonadReader LowerState m, MonadIO m)
           => Relation -> Index -> EIR.Type -> m Type
toLLVMType r idx = go
  where
    go = \case
      EIR.Program ->
        programType <$> ask
      EIR.Iter ->
        typeIter . fromJust . M.lookup (r, idx) <$> asks fnsMap
      EIR.Value ->
        typeValue . fromJust . M.lookup (r, idx) <$> asks fnsMap
      EIR.Void ->
        pure void
      EIR.Pointer ty ->
        ptr <$> go ty

mkArg :: Word8 -> Type -> (Type, ParameterName)
mkArg x ty =
  (ty, ParameterName $ "arg" <> pack [x])

getIndexFromMeta :: Metadata -> Index
getIndexFromMeta = \case
  BTree meta -> Index $ BTree.index meta
