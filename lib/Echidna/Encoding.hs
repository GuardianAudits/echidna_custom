{-# LANGUAGE OverloadedStrings #-}

module Echidna.Encoding
  ( decodeUtf8OrEscaped
  , hexText
  , jsonValueText
  ) where

import Data.Aeson (Value)
import Data.Aeson.Text qualified as AesonText
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as BS16
import Data.Char (chr)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Word (Word8)
import Numeric (showHex)

decodeUtf8OrEscaped :: ByteString -> Text
decodeUtf8OrEscaped bs =
  case TE.decodeUtf8' bs of
    Right t -> t
    Left _ -> T.concat (escapeByte <$> BS.unpack bs)

hexText :: ByteString -> Text
hexText = TE.decodeLatin1 . ("0x" <>) . BS16.encode

jsonValueText :: Value -> Text
jsonValueText = TL.toStrict . AesonText.encodeToLazyText

escapeByte :: Word8 -> Text
escapeByte w
  | w == 0x5c = "\\\\"
  | w >= 0x20 && w <= 0x7e = T.singleton (chr (fromIntegral w))
  | otherwise = "\\x" <> paddedHex w

paddedHex :: Word8 -> Text
paddedHex w =
  let h = showHex w ""
  in T.pack $ if length h == 1 then '0' : h else h
