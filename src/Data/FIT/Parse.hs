{-# LANGUAGE DoAndIfThenElse, OverloadedStrings, TupleSections #-}
module Data.FIT.Parse
  ( parseBytes
  , parseFile
) where
import Control.Applicative ((*>), (<$>), (<*>))
import Control.Monad.State
import Control.Monad.Trans.Either
import qualified Data.Binary.Get as G
import Data.Bits
import qualified Data.ByteString.Lazy as B
import Data.Int (Int64)
import Data.FIT.Parse.Format (fieldGetter, isSignedField)
import Data.FIT.Parse.Util
import Data.List (find)
import qualified Data.Map as M
import Data.Maybe (catMaybes, maybeToList)
import Data.Running
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Format ()
import Data.Word (Word8, Word16)

data Data = Data
  { dataId :: Word16
  , dataFields :: [(Word8, Int64)]
  } deriving (Eq, Ord, Show)

type Definition = [(Word8, G.Get Int64)]
type Definitions = [((Word8, Word16), Definition)]

lGetWord8 :: MonadTrans t => t G.Get Word8
lGetWord8 = lift G.getWord8

parseDefinition :: EitherT Text G.Get (Word16, Definition)
parseDefinition =
  do
    _      <- lift (G.skip 2)
    global <- lift G.getWord16le
    count  <- fromIntegral <$> lGetWord8
    def <- replicateM count $ parseField global
    return (global, def)
  where
    action :: G.Get (Either Text (G.Get Int64))
    action = fieldGetter <$> G.getWord8 <*> (isSignedField <$> G.getWord8)

    parseField :: Word16 -> EitherT Text G.Get (Word8, G.Get Int64)
    parseField global =
      (,) <$> lGetWord8 <*> (hoistEither =<< lift action)

-- | Note that we're not actually using the either monad here.
parseDataFields :: Definition -> EitherT Text G.Get [(Word8, Int64)]
parseDataFields = mapM readField 
  where
    readField (fieldId, action) = (,) fieldId <$> lift action

parseRecord :: StateT Definitions (EitherT Text G.Get) (Maybe Data)
parseRecord = do
  header <- lift lGetWord8
  let recordId = header .&. 0xf
  if (header .&. 0x40) == 0x40
  then (lift parseDefinition >>= \(global, def) -> modify (((recordId, global), def) :)) *> return Nothing
  else do
    ((_, global), definition) <- (maybe typeError return . find ((== recordId) . fst . fst)) =<< get
    Just . Data global <$> lift (parseDataFields definition)
    where typeError = lift $ left "Unknown data message type!"

parseRecords :: Int -> StateT Definitions (EitherT Text G.Get) [Data]
parseRecords size = do
  bytesRead <- lift . lift $ fromIntegral <$> G.bytesRead
  if bytesRead == size
  then return []
  else (++) <$> (maybeToList <$> parseRecord) <*> parseRecords size

pointRecords :: [Data] -> [PointRecord]
pointRecords = catMaybes . map selectPointRecord
  where
    selectPointRecord (Data 20 fields) = PointRecord
      <$> (toUTCTime <$> lookup 253 fields)
      <*> (curry Coord <$> (toDegree <$> lookup 0 fields) <*> (toDegree <$> lookup 1 fields))
      <*> ((/ 100) . fromIntegral <$> lookup 5 fields)
      <*> ((/ 1000) . fromIntegral <$> lookup 5 fields)
    selectPointRecord _ = Nothing 

parseFIT :: Word16 -> EitherT Text G.Get [PointRecord]
parseFIT crc = do
  headerSize <- fromIntegral <$> lGetWord8
  protocolVersion <- (\w -> (shiftR (240 .&. w) 4, 0x0f .&. w)) <$> lGetWord8
  profileVersion <- lift G.getWord16le
  contentSize <- fromIntegral <$> lift G.getWord32le
  ext <- decodeUtf8 <$> lift (G.getByteString 4)
  when (ext /= ".FIT") $ left "Invalid file header!"
  _ <- lift . G.skip $ headerSize - 12
  (records, defs) <- runStateT (parseRecords $ contentSize + headerSize) []
  check <- (crc ==) <$> lift G.getWord16le
  unless check $ left "File corrupted (invalid checksum)!"
  return $ pointRecords records

-- | Parse a lazy byte string representing a FIT file. Note that we force
-- evaluation of most of the string immediately, to compute the checksum. This
-- isn't necessarily ideal, but these files tend to be small.
parseBytes :: B.ByteString -> Either Text [PointRecord]
parseBytes contents = G.runGet (runEitherT $ parseFIT crc) contents
  where
    crc = computeCRC16 $ B.take (B.length contents - 2) contents

-- | A convenience function that parses a file and ignores errors. 
parseFile :: FilePath -> IO [PointRecord] 
parseFile file = do
  contents <- B.readFile file 
  let crc = computeCRC16 $ B.take (B.length contents - 2) contents
  let Right parsed = G.runGet (runEitherT $ parseFIT crc) contents
  return parsed

