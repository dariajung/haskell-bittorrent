module Torrent where

import Data.IORef
import Data.Array.IO
import Network
import Network.HTTP
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as Lz
import qualified Data.List as L
import qualified Network.Socket.ByteString as NB
import Control.Concurrent
import System.IO
import Text.Printf
import Data.List.Split (chunksOf)
import Control.Monad
import Data.Array.IO
import Data.IORef
import Data.Maybe

import Peer
import Metadata
import Config
import Bencode
import Protocol
import Piece
import Initiator

-- in big endian
bitfield = C.pack "\255\23\255\155\5\232\255\255\255\255\135\255\255\255\255\255\255\255\255\191\255\255\255\253\255\255\255\191\255\255\255\255\255\255\255\255\254\255\255\251\255\255\255\254\255\255\255\255\255\251\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\223\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\253\255\255\255\255\255\255\255\223\255\255\255\255\255\255\255\223\223\DEL\255\255\255\255\255\255\255\223\255\255\255\255\255\255\255\255\253\255\255\255\255\255\255\255\255\255\239\255\255\255\255\255\253\255\223\255\255\255\255\255\255\255\255\255\255\253\255\255\255\239\255\255\255\255\251\255\255\255\255\255\255\255\251\255\255\255\191\255\255\255\255\254\255\255\255\255\255\255\NUL"

{-- 
    translate a bitfield to an array of bits (0s and 1s) 
    and then translate that to an array of Bools
    bitfield is not big endian 
--}
translateBF bitfield = do
    return $ binaryToBool $ L.concat $ L.init $ map toBinary $ map (fromEnum) $ B.unpack bitfield

binaryToBool (x:xs)
    | x == 1        = True : binaryToBool xs
    | otherwise     = False : binaryToBool xs
binaryToBool [] = []

data Torrent = Torrent {
    metadata :: Metadata, -- the metadata for a torrent
    inactivePeers :: IORef [InactivePeer], -- the list of inactive peers
    activePeers :: IORef [ActivePeer], -- the list of active peers
    pieces ::  IOArray Int Piece, -- the pieces for this torrent
    initiator :: Initiator
}

-- generate torrent data type
generateTorrent :: IO Torrent
generateTorrent = do 
    metainfo <- getMetaData
    lPieces <- mapM (\x -> genPiece (read (pieceLength metainfo) :: Int) 
        (infoPieceHash metainfo x) x) [0..(read (pieceCount metainfo)::Int)]
    inactv <- newIORef []
    actv <- newIORef [] 
    pieceArr <- newListArray (0, (read (pieceCount metainfo) :: Int) - 1) lPieces
    _initiator <- defaultInitiator
    return Torrent {
        metadata = metainfo,
        inactivePeers = inactv,
        activePeers = actv,
        pieces = pieceArr,
        initiator = _initiator
    }

-- start everything off
start = do
    torrent <- generateTorrent
    peers <- genInactivePeers
    sequence $ map (forkIO . initiateHandshake torrent) peers -- fork peers
    return ()

initiateHandshake torrent peer = do
    putStrLn $ "Connecting to " ++ (Peer.ip peer) ++ ":" ++ (show $ Peer.port peer)
    handle <- Network.connectTo (Peer.ip peer) (Network.PortNumber $ fromIntegral $ Peer.port peer)
    hSetBuffering handle LineBuffering
    putStrLn $ "Sending handshake to " ++ (Peer.ip peer) ++ ":" ++ (show $ Peer.port peer)
    sendHandshake handle
    activePeer <- recvHandshake (metadata torrent) handle
    addActivePeer activePeer (activePeers torrent)
    loopRecvMsg torrent activePeer

loopRecvMsg torrent peer = forever $ do
    (msg, payload) <- recvMessage (pHandle peer)
    processMessage torrent peer (msg, payload)

{-- 
recvMessage parses message
which gives (Msg, [C.ByteString]), pass this to processMessage 

block size: 16384 kb
--}
processMessage torrent peer (msgType, payload) = 
    case msgType of
        -- return nothing on receiving Keep Alive
        MsgKeepAlive -> return ()
        -- Peer is choking, update peer data and send interested message
        MsgChoke -> do 
            writeIORef (pChoking peer) True
            sendMessage (pHandle peer) (MsgInterested) [B.empty]
        -- yay peer has unchoked me, time to request
        MsgUnchoke -> do
            writeIORef (pChoking peer) False -- peer has stopped choking me.
            writeIORef (pAmInterested peer) True -- I am interested in this peer.
            indexWant <- readIORef (pWanted peer) -- get the wanted piece from this peer.
            if indexWant == -1
                then return ()
                else do
                    piece <- readArray (pieces torrent) indexWant
                    pieceBitfield <- getElems $ pBitfield piece
                    let begin = fromJust $ L.elemIndex False pieceBitfield
                    putStrLn $ "\n\tMaking a request for piece " ++ (show indexWant) ++ " with block index " ++ (show begin)
                    sendMessage (pHandle peer) (MsgRequest) $ map writeBEByteStringInt [indexWant, begin * 16384, 16384]
        -- don't send unchoke because I'm not uploading...
        MsgInterested -> do
            writeIORef (pInterested peer) True
        -- disconnect connection? or just wait for interested message?
        MsgNotInterested -> do
            writeIORef (pInterested peer) False
        MsgHave -> do
            let index = readBEInt $ head payload
            writeIORef (pWanted peer) index

            piece <- readArray (pieces torrent) index
            done <- readIORef $ pDone piece
            amInterested <- readIORef $ pAmInterested peer 
            choked <- readIORef $ pChoking peer 

            pieceBitfield <- getElems $ pBitfield piece
            let begin = fromJust $ L.elemIndex False pieceBitfield

            {-- 
                if the piece hasn't finished downloading,
                and I am interested in this peer, send a
                request message. Check to see if peer 
                has unchoked me. Otherwise, send an 
                interested message.
            --}
            if (not done && amInterested && not choked) 
                then do
                    sendMessage (pHandle peer) (MsgRequest) $ map writeBEByteStringInt [index, begin * 16384, 16384]
                else do
                    writeIORef (pAmInterested peer) True
                    writeIORef (pWanted peer) index
                    sendMessage (pHandle peer) MsgInterested [B.empty]

        MsgBitfield -> do
            binary <- translateBF $ head payload
            let zipped = zip [0..(read (pieceCount $ metadata torrent) :: Int) - 1] binary
            -- update peer bitfield
            sequence $ map (\(i, e) -> do { writeArray (pBitField peer) i e }) zipped
            -- need to cross reference against own bitfield and request pieces peer has
            -- but i don't have

            return ()

