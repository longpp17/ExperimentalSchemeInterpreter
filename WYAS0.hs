{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# OPTIONS_GHC -Wno-overlapping-patterns #-}

import Text.ParserCombinators.Parsec hiding (spaces)
import System.Environment
import Control.Monad
import Data.Typeable
import Data.Char (isNumber, isSymbol)
import Data.IORef
import Control.Monad.Except
import System.IO
import GHC.TopHandler (runIO)
import System.Console.Haskeline
import GHC.ExecutionStack (Location(functionName))


{-|

Adapted from the wikibook https://en.wikibooks.org/wiki/Write_Yourself_a_Scheme_in_48_Hours

Corresponds to the progress made by the end of Chapter 3, Evaluation Part 1.

-}



-- Parser

data LispVal = Atom   String
             | List   [LispVal]
             | DottedList [LispVal] LispVal
             | Number Integer
             | Str    String
             | Bool   Bool
             | PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
             | Func { params :: [String], vararg :: (Maybe String), body :: [LispVal], closure :: Env }
        

data LispError = NumArgs Integer [LispVal]
               | TypeMismatch String LispVal
               | Parser ParseError
               | NotImplemented String
               | BadSpecialForm String LispVal
               | NotFunction String String
               | UnboundVar String String
               | Default String
               

instance Show LispVal where
  show = renderVal

showError :: LispError -> String
showError (UnboundVar message varname)  = message ++ ": " ++ varname
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func)    = message ++ ": " ++ show func
showError (NumArgs expected found)      = "Expected " ++ show expected
                                       ++ " args; found values " ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected
                                       ++ ", found " ++ show found
showError (Parser parseErr)             = "Parse error at " ++ show parseErr

instance Show LispError where show = showError

type ThrowsError = Either LispError

trapError action = catchError action (return . show)

extractValue :: ThrowsError a -> a
extractValue (Right val) = val

symbol :: Parser Char
symbol = oneOf "!#$%&|*+-/:<=>?@^_~"

spaces :: Parser ()
spaces = skipMany1 space

parseString :: Parser LispVal
parseString = do
                char '"'
                x <- many (noneOf "\"")
                char '"'
                return $ Str x

parseAtom :: Parser LispVal
parseAtom = do
              first <- letter <|> symbol
              rest <- many (letter <|> digit <|> symbol)
              let atom = first:rest
              return $ case atom of
                         "#t" -> Bool True
                         "#f" -> Bool False
                         "else" -> Bool True
                         _    -> Atom atom

parseNumber :: Parser LispVal
parseNumber = fmap (Number . read) $ many1 digit

{-readExpr :: String -> String
readExpr input = case parse parseExpr "lisp" input of
    Left err  -> "No match: " ++ show err
    Right val -> "Found value: `" ++ (show val) ++"'"-}

readExpr :: String -> ThrowsError LispVal
readExpr input = case parse parseExpr "lisp" input of
    Left err  -> throwError $ Parser err
    Right val -> return val

parseList :: Parser LispVal
parseList = fmap List $ sepBy parseExpr spaces

parseDottedList :: Parser LispVal
parseDottedList = do
    head <- endBy parseExpr spaces
    tail <- char '.' >> spaces >> parseExpr
    return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted = do
    char '\''
    x <- parseExpr
    return $ List [Atom "quote", x]

parseExpr :: Parser LispVal
parseExpr = parseAtom
         <|> parseString
         <|> parseNumber
         <|> parseQuoted
         <|> do char '('
                x <- try parseList <|> parseDottedList
                char ')'
                return x
renderVal :: LispVal -> String
renderVal (Str contents)          = "\"" ++ contents ++ "\""
renderVal (Atom name)             = name
renderVal (Number contents)       = show contents
renderVal (Bool True)             = "#t"
renderVal (Bool False)            = "#f"
renderVal (List contents)         = "(" ++ unwordsList contents ++ ")"
renderVal (DottedList head tail)  = "(" ++ unwordsList head ++ " . " ++ renderVal tail ++ ")"
renderVal (PrimitiveFunc _)       = "<primitive>"
renderVal (Func {params = args
                , vararg = varargs
                , body = body
                , closure = env}) = "(lambda (" ++ unwords (map show args) ++
                                   (case varargs of
                                       Nothing  -> ""
                                       Just arg -> " . " ++ arg) ++ ") ...)"


unwordsList :: [LispVal] -> String
unwordsList = unwords . map renderVal

-- Variables and assignment

type Env = IORef [(String, IORef LispVal)]

nullEnv :: IO Env
nullEnv = newIORef []

type IOThrowsError = ExceptT LispError IO

liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err) = throwError err
liftThrows (Right val) = return val

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = runExceptT (trapError action) >>= return . extractValue

isBound :: Env -> String -> IO Bool
isBound envRef var = readIORef envRef >>= return . maybe False (const True) . lookup var

getVar :: Env -> String -> IOThrowsError LispVal
getVar envRef var =  do
                        env <- liftIO $ readIORef envRef
                        maybe (throwError $ UnboundVar "Getting an unbound variable" var)
                              (liftIO . readIORef)
                              (lookup var env)


setVar :: Env -> String -> LispVal -> IOThrowsError LispVal
setVar envRef var value = do
                            env <- liftIO $ readIORef envRef
                            maybe (throwError $ UnboundVar "Setting an unbound variable" var)
                                  (liftIO . (flip writeIORef value))
                                  (lookup var env)
                            return value

defineVar :: Env -> String -> LispVal -> IOThrowsError LispVal
defineVar envRef var value = do
                                alreadyDefined <- liftIO $ isBound envRef var
                                if alreadyDefined
                                  then setVar envRef var value >> return value
                                  else liftIO $ do
                                                    valueRef <- newIORef value
                                                    env <- readIORef envRef
                                                    writeIORef envRef ((var, valueRef) : env)
                                                    return value

                            
bindVars :: Env -> [(String, LispVal)] -> IO Env
bindVars envRef bindings = readIORef envRef >>= extendEnv bindings >>= newIORef
                            where extendEnv bindings env = liftM (++ env) (mapM addBinding bindings)
                                  addBinding (var, value) = do 
                                                                ref <- newIORef value
                                                                return (var, ref)



makeFunc :: Monad m => Maybe String -> Env -> [LispVal] -> [LispVal] -> m LispVal
makeFunc varargs env params body = return $ Func (map renderVal params) varargs body env

makeNormalFunc = makeFunc Nothing

makeVarArgs = makeFunc . Just . renderVal


-- Evaluator 

eval :: Env -> LispVal -> IOThrowsError LispVal
eval env val@(Str _)    = return val
eval env val@(Number _) = return val
eval env val@(Bool _)   = return val
eval env (Atom id) = getVar env id

eval env (List [Atom "quote", val]) = return val
eval env (List [Atom "if", pred, conseq, alt]) =
    do result <- eval env pred
       case result of
         Bool False -> eval env alt
         otherwise  -> eval env conseq

eval env (List (Atom "cond" : clauses)) = evalClauses clauses
    where 
        evalClauses (List [pred, conseq] : xs) = do
            result <- eval env pred
            case result of
                Bool False -> evalClauses xs
                Bool True  -> eval env conseq
        evalClauses [] = throwError $ BadSpecialForm "No true clause in cond expression: " (List clauses)        
        evalClauses _ = throwError $ BadSpecialForm "malformed cond expression" $ List (Atom "cond" : clauses) 

eval env (List [Atom "cond" , List [Atom "else", alt]]) = eval env alt
eval env (List [Atom "define", Atom var, form]) = eval env form >>= defineVar env var
eval env (List (Atom "define" : List (Atom var : params) : body)) =
     makeNormalFunc env params body >>= defineVar env var
eval env (List (Atom "define" : DottedList (Atom var : params) varargs : body)) =
     makeVarArgs varargs env params body >>= defineVar env var
eval env (List (Atom "let" : List bindings : body)) = do
     newEnv <- liftIO $ bindVars env _bindings
     eval newEnv $ head body
    where _bindings = zip names values
          names = map (\(List [Atom name, _]) -> name) bindings
          values = map (\(List [_, val]) -> val) bindings
eval env (List (Atom "let" : DottedList bindings varargs : body)) = do
     newEnv <- liftIO $ bindVars env _bindings
     eval newEnv $ List body
    where _bindings = zip names values
          names = map (\(List [Atom name, _]) -> name) bindings
          values = map (\(List [_, val]) -> val) bindings
eval env (List (Atom "let" : args)) = throwError $ NumArgs 2 args

eval env (List (Atom "lambda" : List params : body)) =
     makeNormalFunc env params body
eval env (List (Atom "lambda" : DottedList params varargs : body)) =
     makeVarArgs varargs env params body
eval env (List (Atom "lambda" : varargs@(Atom _) : body)) =
     makeVarArgs varargs env [] body
eval env (List [Atom "set!", Atom var, form]) = eval env form >>= setVar env var
eval env (List (function : args)) = do
     func <- eval env function
     argVals <- mapM (eval env) args
     apply func argVals
eval env badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

-- TODO: define a composition function syntax that just like . in haskell
-- TODO: Type Annotation?

car :: [LispVal] -> ThrowsError LispVal
car [List (x : xs)]         = return x
car [DottedList (x : xs) _] = return x
car [badArg]                = throwError $ TypeMismatch "pair" badArg
car badArgList              = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x : xs)]         = return $ List xs
cdr [DottedList [_] x]      = return x
cdr [DottedList (_ : xs) x] = return $ DottedList xs x
cdr [badArg]                = throwError $ TypeMismatch "pair" badArg
cdr badArgList              = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []] = return $ List [x1]
cons [x, List xs]  = return $ List $ x : xs
cons [x, DottedList xs xlast] = return $ DottedList (x : xs) xlast
cons [x1, x2]      = return $ DottedList [x1] x2
cons badArgList    = throwError $ NumArgs 2 badArgList


eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool arg1), (Bool arg2)]     = return $ Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)] = return $ Bool $ arg1 == arg2
eqv [(Str arg1), (Str arg2)]       = return $ Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)]     = return $ Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(List arg1), (List arg2)]     = return $ Bool $ (length arg1 == length arg2) &&
                                                      (all eqvPair $ zip arg1 arg2)
    where eqvPair (x1, x2) = case eqv [x1, x2] of
                               Left err         -> False
                               Right (Bool val) -> val
eqv [_, _]                         = return $ Bool False
eqv badArgList                     = throwError $ NumArgs 2 badArgList


data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

unpackEquals arg1 arg2 (AnyUnpacker unpacker) =
      do
          unpacked1 <- unpacker arg1
          unpacked2 <- unpacker arg2
          return $ unpacked1 == unpacked2
      `catchError` const (return False)
     `catchError` const (return False)


equal :: [LispVal] -> ThrowsError LispVal
equal [arg1, arg2] = do
    primitiveEquals <- liftM or $ mapM (unpackEquals arg1 arg2)
                        [AnyUnpacker unpackNum, AnyUnpacker unpackStr, AnyUnpacker unpackBool]
    eqvEquals <- eqv [arg1, arg2]
    return $ Bool $ (primitiveEquals || let (Bool x) = eqvEquals in x)




apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func params varargs body closure) args =
      if num params /= num args && varargs == Nothing
         then throwError $ NumArgs (num params) args
         else (liftIO $ bindVars closure $ zip params args) >>= bindVarArgs varargs >>= evalBody
      where remainingArgs = drop (length params) args
            num = toInteger . length
            evalBody env = liftM last $ mapM (eval env) body
            bindVarArgs arg env = case arg of
                Just argName -> liftIO $ bindVars env [(argName, List $ remainingArgs)]
                Nothing -> return env
apply _ _ = error "apply error"


primitiveBindings :: IO Env
primitiveBindings = nullEnv >>= (flip bindVars $ map makePrimitiveFunc primitives)
     where makePrimitiveFunc (var, func) = (var, PrimitiveFunc func)                

primitives :: [(String, [LispVal] -> ThrowsError  LispVal)]
primitives = [("+", numericBinop (+)),
              ("-", numericBinop (-)),
              ("*", numericBinop (*)),
              ("/", numericBinop div),
              ("mod", numericBinop mod),
              ("quotient", numericBinop quot),
              ("%", numericBinop rem),
              ("string?", typeCheckop valueIsString),
              ("number?", typeCheckop valueIsNumber),
              ("symbol?", typeCheckop valueIsSymbol),
              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("/=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("&&", boolBoolBinop (&&)),
              ("||", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string<?", strBoolBinop (<)),
              ("string>?", strBoolBinop (>)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv),
              ("equal?", equal)]

valueIsString :: LispVal -> Bool
valueIsString (Str _) = True
valueIsString _       = False

valueIsNumber :: LispVal -> Bool
valueIsNumber (Number _) = True
valueIsNumber _          = False

valueIsSymbol :: LispVal -> Bool
valueIsSymbol (Atom _) = True
valueIsSymbol _        = False

typeCheckop :: (LispVal -> Bool) -> [LispVal] -> ThrowsError LispVal
typeCheckop op [x] = return $ Bool $ op x
typeCheckop _ _ = throwError $ NumArgs 1 []

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op           []  = throwError $ NumArgs 2 []
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params        = mapM unpackNum params >>= return . Number . foldl1 op

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
                             then throwError $ NumArgs 2 args
                             else do
                                      left <- unpacker $ args !! 0
                                      right <- unpacker $ args !! 1
                                      return $ Bool $ left `op` right

numBoolBinop  = boolBinop unpackNum
strBoolBinop  = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackStr :: LispVal -> ThrowsError String
unpackStr (Str s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s) = return $ show s
unpackStr notString = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool  = throwError $ TypeMismatch "boolean" notBool

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (Str n) = let parsed = reads n in
                           if null parsed
                             then throwError $ TypeMismatch "number" $ Str n
                             else return $ fst $ parsed !! 0
unpackNum (List [n]) = unpackNum n
unpackNum notNum     = throwError $ TypeMismatch "number" notNum


-- REPL

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: Env -> String -> IO String
evalString env expr = runIOThrows $ liftM show $ (liftThrows $ readExpr expr) >>= eval env

evalAndPrint :: Env -> String -> IO ()
evalAndPrint env expr = evalString env expr >>= putStrLn

runOne :: String -> IO ()
runOne expr = primitiveBindings >>= flip evalAndPrint expr


until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ p prompt action = do
    result <- prompt
    if p result
        then return ()
        else action result >> until_ p prompt action

runRepl :: IO ()
runRepl = primitiveBindings >>= until_ (== "quit") (readPrompt "Lisp>>> ") . evalAndPrint
    
main :: IO ()
main = do args <- getArgs
          case length args of
               0 -> runRepl
               1 -> runOne $ args !! 0
               _ -> putStrLn "Program takes only 0 or 1 argument"


