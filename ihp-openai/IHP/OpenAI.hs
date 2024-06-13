module IHP.OpenAI where

import Data.Text (Text)
import Data.ByteString (ByteString)
import Control.Exception (SomeException)
import Data.IORef

import qualified System.IO.Streams as Streams
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString
import Network.Http.Client
import Data.Aeson
import OpenSSL
import qualified OpenSSL.Session as SSL
import qualified Data.Text as Text
import qualified Control.Retry as Retry
import qualified Control.Exception as Exception
import Control.Applicative ((<|>))
import qualified Data.Aeson.Key as Key
import qualified Data.Maybe as Maybe

data CompletionRequest = CompletionRequest
    { messages :: ![Message]
    , model :: !Text
    , maxTokens :: !(Maybe Int)
    , temperature :: !(Maybe Double)
    , presencePenalty :: !(Maybe Double)
    , frequencePenalty :: !(Maybe Double)
    , stream :: !Bool
    , responseFormat :: !(Maybe ResponseFormat)
    , tools :: ![Tool]
    } deriving (Eq, Show)

data Message = Message
    { role :: !Role
    , content :: !Text
    , name :: !(Maybe Text)
    , toolCallId :: !(Maybe Text)
    , toolCalls :: ![ToolCall]
    } deriving (Eq, Show)

data Role
    = UserRole
    | SystemRole
    | AssistantRole
    | ToolRole
    deriving (Eq, Show)

data ResponseFormat
    = Text
    | JsonObject
    deriving (Eq, Show)

data Tool
    = Function { description :: !(Maybe Text), name :: !Text, parameters :: !(Maybe JsonSchema) }
    deriving (Eq, Show)

data JsonSchema
    = JsonSchemaObject ![Property]
    | JsonSchemaString
    | JsonSchemaInteger
    | JsonSchemaNumber
    | JsonSchemaArray !JsonSchema
    | JsonSchemaEnum ![Text]
    deriving (Eq, Show)

data Property
    = Property { propertyName :: !Text, type_ :: !JsonSchema, required :: !Bool, description :: !(Maybe Text) }
    deriving (Eq, Show)

instance ToJSON CompletionRequest where
    toJSON CompletionRequest { model, messages, maxTokens, temperature, presencePenalty, frequencePenalty, stream, responseFormat, tools } =
        object
            [ "model" .= model
            , "messages" .= messages
            , "max_tokens" .= maxTokens
            , "stream" .= stream
            , "temperature" .= temperature
            , "presence_penalty" .= presencePenalty
            , "frequency_penalty" .= frequencePenalty
            , "response_format" .= responseFormat
            , "tools" .= emptyListToNothing tools
            ]

instance ToJSON Role where
    toJSON UserRole = toJSON ("user" :: Text)
    toJSON SystemRole = toJSON ("system" :: Text)
    toJSON AssistantRole = toJSON ("assistant" :: Text)
    toJSON ToolRole = toJSON ("tool" :: Text)

instance ToJSON Message where
    toJSON Message { role, content, name, toolCallId, toolCalls } = object $ Maybe.catMaybes
        [ Just ("role" .= role)
        , Just ("content" .= content)
        , ("name" .=) <$> name
        , ("tool_call_id" .=) <$> toolCallId
        , if null toolCalls then Nothing else Just ("tool_calls" .= toolCalls)
        ]

instance ToJSON ResponseFormat where
    toJSON Text = object [ "type" .= ("text" :: Text) ]
    toJSON JsonObject = object [ "type" .= ("json_object" :: Text) ]

instance ToJSON Tool where
    toJSON Function { description, name, parameters } =
        object
            [ "type" .= ("function" :: Text)
            , "function" .= (object
                [ "name" .= name
                , "description" .= description
                , "parameters" .= parameters
                ])
            ]

instance ToJSON JsonSchema where
    toJSON (JsonSchemaObject properties) =
        object
            [ "type" .= ("object" :: Text)
            , "properties" .= (object (concat (map (\property -> [ (Key.fromText property.propertyName) .= ((toJSON property.type_) `mergeObj` (object $ Maybe.catMaybes [ ("description" .=) <$> property.description ])) ]) properties)))
            ]
        where
            mergeObj (Object first) (Object second) = Object (first <> second)
            mergeObj _ _ = error "JsonSchema.mergeObj failed with invalid type"
    toJSON JsonSchemaString =
        object [ "type" .= ("string" :: Text) ]
    
    toJSON JsonSchemaInteger =
        object [ "type" .= ("integer" :: Text) ]
    
    toJSON JsonSchemaNumber =
        object [ "type" .= ("number" :: Text) ]
    
    toJSON (JsonSchemaArray items) =
        object
            [ "type" .= ("array" :: Text)
            , "items" .= items
            ]
    
    toJSON (JsonSchemaEnum values) =
        object
            [ "type" .= ("string" :: Text)
            , "enum" .= values
            ]        

userMessage :: Text -> Message
userMessage content = Message { role = UserRole, content, name = Nothing, toolCallId = Nothing, toolCalls = [] }

systemMessage :: Text -> Message
systemMessage content = Message { role = SystemRole, content, name = Nothing, toolCallId = Nothing, toolCalls = [] }

assistantMessage :: Text -> Message
assistantMessage content = Message { role = AssistantRole, content, name = Nothing, toolCallId = Nothing, toolCalls = [] }

toolMessage :: Text -> Message
toolMessage content = Message { role = ToolRole, content, name = Nothing, toolCallId = Nothing, toolCalls = [] }

newCompletionRequest :: CompletionRequest
newCompletionRequest = CompletionRequest
    { messages = []
    , maxTokens = Nothing
    , temperature = Nothing
    , presencePenalty = Nothing
    , frequencePenalty = Nothing
    , model = "gpt-3.5-turbo"
    , stream = False
    , responseFormat = Nothing
    , tools = []
    }

data CompletionResult = CompletionResult
    { choices :: [Choice]
    }

instance FromJSON CompletionResult where
    parseJSON = withObject "CompletionResult" $ \v -> CompletionResult
        <$> v .: "choices"

-- [{"text": "Introdu", "index": 0, "logprobs": null, "finish_reason": null}]
data Choice = Choice
    { text :: !Text
    }

instance FromJSON Choice where
    parseJSON = withObject "Choice" $ \v -> do
        deltaOrMessage <- (v .: "message") <|> (v .: "delta")
        content <- deltaOrMessage .: "content"
        pure Choice { text = content }


streamCompletion :: ByteString -> CompletionRequest -> IO () -> (CompletionChunk -> IO ()) -> IO [CompletionChunk]
streamCompletion secretKey completionRequest' onStart callback = do
        let completionRequest = enableStream completionRequest'
        completionRequestRef <- newIORef completionRequest
        result <- Retry.retrying retryPolicyDefault shouldRetry (action completionRequestRef)
        case result of
            Left (e :: SomeException) -> Exception.throwIO e
            Right (Left e) -> error (Text.unpack e)
            Right (Right r) -> pure r
    where
        shouldRetry retryStatus (Left e) = pure True
        shouldRetry retryStatus (Right (Left _)) = pure True
        shouldRetry retryStatus (Right (Right r)) = pure False
        action completionRequestRef retryStatus = do
            completionRequest <- readIORef completionRequestRef
            let onStart' = if retryStatus.rsIterNumber == 0 then onStart else pure ()
            Exception.try (streamCompletionWithoutRetry secretKey completionRequest onStart' (wrappedCallback completionRequestRef))

        wrappedCallback completionRequestRef completionChunk = do
            let text = mconcat $ Maybe.mapMaybe (\choiceDelta -> choiceDelta.delta.content) completionChunk.choices
            modifyIORef' completionRequestRef (\completionRequest -> completionRequest
                    { messages = completionRequest.messages <> [assistantMessage text]
                    , maxTokens = case completionRequest.maxTokens of
                        Just maxTokens -> Just $ maxTokens - (length (Text.words text))
                        Nothing -> Nothing
                    }
                )
            callback completionChunk

        retryPolicyDefault = Retry.constantDelay 50000 <> Retry.limitRetries 10

streamCompletionWithoutRetry :: ByteString -> CompletionRequest -> IO () -> (CompletionChunk -> IO ()) -> IO (Either Text [CompletionChunk])
streamCompletionWithoutRetry secretKey completionRequest' onStart callback = do
    let completionRequest = enableStream completionRequest'
    modifyContextSSL (\context -> do
            SSL.contextSetVerificationMode context SSL.VerifyNone
            pure context
        )
    withOpenSSL do
        withConnection (establishConnection "https://api.openai.com/v1/chat/completions") \connection -> do
            let q = buildRequest1 do
                    http POST "/v1/chat/completions"
                    setContentType "application/json"
                    Network.Http.Client.setHeader "Authorization" ("Bearer " <> secretKey)
            sendRequest connection q (jsonBody completionRequest)
            onStart
            receiveResponse connection handler

    where
        handler :: Response -> Streams.InputStream ByteString -> IO (Either Text [CompletionChunk])
        handler response stream = do
            let status = getStatusCode response
            if status == 200
                then do
                    {-
                    parse stream line by line as event stream format according to API spec:
                    https://platform.openai.com/docs/api-reference/chat/create#chat/create-stream
                    https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events#event_stream_format
                    -}
                    state <- Streams.lines stream >>= Streams.foldM (parseResponseChunk' callback) emptyParserState
                    return (Right state.chunks)
                else do
                    x :: ByteString <- Streams.fold mappend mempty stream
                    return (Left $ "an error happend: " <> Text.pack (show x))


        parseResponseChunk' :: (CompletionChunk -> IO ()) -> ParserState -> ByteString -> IO ParserState
        parseResponseChunk' callback state input =
            case parseResponseChunk state input of
                ParserResult { chunk = Just chunk, state } -> do
                    callback chunk
                    pure state
                ParserResult { state } -> pure state

data ParserState = ParserState
    { curBuffer :: !ByteString
    , emptyLineFound :: !Bool
    , chunks :: ![CompletionChunk]
    } deriving (Eq, Show)
data ParserResult = ParserResult
    { chunk :: !(Maybe CompletionChunk)
    , state :: ParserState
    } deriving (Eq, Show)
emptyParserState :: ParserState
emptyParserState = ParserState { curBuffer = "", emptyLineFound = False, chunks = [] }

parseResponseChunk :: ParserState -> ByteString -> ParserResult
parseResponseChunk ParserState { curBuffer, emptyLineFound, chunks } input
    -- input line is empty, but previous was not, append newline to buffer
    | ByteString.null input && not emptyLineFound = ParserResult { chunk = Nothing, state = ParserState { curBuffer = curBuffer <> "\n", emptyLineFound = True, chunks } }
    -- input line is empty, previous line was already empty: message ended, clear buffer
    | ByteString.null input && emptyLineFound = ParserResult { chunk = Nothing, state = ParserState { curBuffer = "", emptyLineFound = True, chunks } }
    -- lines starting with : are comments, ignore
    | ":" `ByteString.isPrefixOf` input = ParserResult { chunk = Nothing, state = ParserState { curBuffer = curBuffer, emptyLineFound = False, chunks } }
    -- try to parse line together with buffer otherwise
    | otherwise = case ByteString.stripPrefix "data: " (ByteString.strip (curBuffer <> input)) of
            -- the stream terminated by a data: [DONE] message
            Just "[DONE]" ->
                ParserResult { chunk = Nothing, state = ParserState { curBuffer, emptyLineFound, chunks } }
            Just json ->
                case eitherDecodeStrict json of
                    Right (completionChunk :: CompletionChunk) ->
                        ParserResult
                            { chunk = Just completionChunk
                            , state = ParserState { curBuffer = "", emptyLineFound = False, chunks = chunks <> [completionChunk] }
                            }
                    Left err -> error (show err <> " while parsing " <> show input)
                        --ParserResult
                        --    { chunk = Nothing
                        --    , state = ParserState { curBuffer = curBuffer <> json, emptyLineFound = False, chunks = chunks } }
            Nothing ->
                ParserResult
                    { chunk = Nothing
                    , state = ParserState { curBuffer = curBuffer <> input, emptyLineFound = False, chunks = chunks } }


fetchCompletion :: ByteString -> CompletionRequest -> IO Text
fetchCompletion secretKey completionRequest = do
        result <- Retry.retrying retryPolicyDefault shouldRetry action
        case result of
            Left (e :: SomeException) -> Exception.throwIO e
            Right result -> pure result
    where
        shouldRetry retryStatus (Left _) = pure True
        shouldRetry retryStatus (Right _) = pure False
        action retryStatus = Exception.try (fetchCompletionWithoutRetry secretKey completionRequest)

        retryPolicyDefault = Retry.constantDelay 50000 <> Retry.limitRetries 10

fetchCompletionWithoutRetry :: ByteString -> CompletionRequest -> IO Text
fetchCompletionWithoutRetry secretKey completionRequest = do
        modifyContextSSL (\context -> do
                SSL.contextSetVerificationMode context SSL.VerifyNone
                pure context
            )
        withOpenSSL do
            withConnection (establishConnection "https://api.openai.com/v1/chat/completions") \connection -> do
                    let q = buildRequest1 do
                                http POST "/v1/chat/completions"
                                setContentType "application/json"
                                Network.Http.Client.setHeader "Authorization" ("Bearer " <> secretKey)

                    sendRequest connection q (jsonBody completionRequest)
                    completionResult :: CompletionResult <- receiveResponse connection jsonHandler
                    pure (mconcat $ map (.text) completionResult.choices)

enableStream :: CompletionRequest -> CompletionRequest
enableStream completionRequest = completionRequest { stream = True }

data CompletionChunk = CompletionChunk
    { id :: !Text
    , choices :: [CompletionChunkChoice]
    , created :: Int
    , model :: !Text
    , systemFingerprint :: !(Maybe Text)
    } deriving (Eq, Show)

instance FromJSON CompletionChunk where
    parseJSON = withObject "CompletionChunk" $ \v -> CompletionChunk
        <$> v .: "id"
        <*> v .: "choices"
        <*> v .: "created"
        <*> v .: "model"
        <*> v .: "system_fingerprint"

data CompletionChunkChoice
     = CompletionChunkChoice { delta :: !Delta }
     deriving (Eq, Show)

instance FromJSON CompletionChunkChoice where
    parseJSON = withObject "CompletionChunkChoice" $ \v -> CompletionChunkChoice
        <$> v .: "delta"

data Delta
     = Delta
     { content :: !(Maybe Text)
     , toolCalls :: !(Maybe [ToolCall])
     , role :: !(Maybe Role)
     } deriving (Eq, Show)

instance FromJSON Delta where
    parseJSON = withObject "Delta" $ \v -> Delta
        <$> v .:? "content"
        <*> v .:? "tool_calls"
        <*> v .:? "role"

instance FromJSON Role where
    parseJSON (String "user") = pure UserRole
    parseJSON (String "system") = pure SystemRole
    parseJSON (String "assistant") = pure AssistantRole
    parseJSON (String "ToolRole") = pure ToolRole
    parseJSON otherwise = fail ("Failed to parse role" <> show otherwise)

data ToolCall
    = FunctionCall
    { index :: !Int
    , id :: !(Maybe Text)
    , name :: !(Maybe Text)
    , arguments :: !Text
    } deriving (Eq, Show)

instance FromJSON ToolCall where
    parseJSON = withObject "ToolCall" $ \v -> do
        index <- v .: "index"
        id <- v .:? "id"

        function <- v .: "function"
        name <- function .:? "name"
        arguments <- function .: "arguments"

        pure FunctionCall { index, id, name, arguments }

instance ToJSON ToolCall where
    toJSON FunctionCall { index, id, name, arguments } =
        object
            [ "index" .= index
            , "id" .= id
            , "type" .= ("function" :: Text)
            , "function" .= object [ "name" .= name, "arguments" .= arguments ]
            ]

-- [{"text": "Introdu", "index": 0, "logprobs": null, "finish_reason": null}]


emptyListToNothing :: [value] -> Maybe [value]
emptyListToNothing [] = Nothing
emptyListToNothing values = Just values