from solders.pubkey import Pubkey
from solders.keypair import Keypair
from solders.system_program import ID as SYS_PROGRAM_ID
from solders.transaction import Transaction
from solders.instruction import Instruction
from solders.rpc.config import RpcConfig
from solders.rpc.responses import GetLatestBlockhashResponse
import asyncio
import aiohttp
import json
import base58
import struct
from pathlib import Path
import os
from dotenv import load_dotenv
from image_processor import WallyImageProcessor

def encode_branding_data(branding_data: dict) -> bytes:
    """Encode branding data into bytes for the instruction."""
    # Instruction discriminator for update_branding (first 8 bytes of sha256("global:update_branding"))
    DISCRIMINATOR = bytes([186, 41, 124, 13, 85, 110, 52, 23])
    
    # Encode strings as bytes with length prefix
    def encode_string(s: str) -> bytes:
        encoded = s.encode('utf-8')
        return struct.pack("<I", len(encoded)) + encoded
    
    # Encode the branding data
    encoded = DISCRIMINATOR
    encoded += encode_string(branding_data['name'])
    encoded += encode_string(branding_data['symbol'])
    encoded += encode_string(branding_data['description'])
    encoded += encode_string(branding_data['logo_uri'])
    
    # Encode images
    for img_type in ['token', 'twitter', 'telegram', 'discord', 'favicon', 'high_res']:
        encoded += encode_string(branding_data['images'][img_type])
    
    # Encode colors
    for color in ['primary', 'secondary', 'accent', 'background']:
        encoded += encode_string(branding_data['colors'][color])
    
    # Encode official links
    for link_type in ['website', 'twitter', 'telegram', 'discord']:
        encoded += encode_string(branding_data['official_links'][link_type])
    
    return encoded

class SolanaClient:
    def __init__(self, rpc_url: str):
        self.rpc_url = rpc_url
        self.session = None

    async def __aenter__(self):
        self.session = aiohttp.ClientSession()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()

    async def get_latest_blockhash(self) -> str:
        async with self.session.post(
            self.rpc_url,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "getLatestBlockhash",
                "params": [{"commitment": "finalized"}]
            }
        ) as response:
            result = await response.json()
            return result["result"]["value"]["blockhash"]

    async def send_transaction(self, signed_tx: bytes) -> str:
        async with self.session.post(
            self.rpc_url,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "sendTransaction",
                "params": [
                    base58.b58encode(signed_tx).decode("ascii"),
                    {"encoding": "base58", "preflightCommitment": "confirmed"}
                ]
            }
        ) as response:
            result = await response.json()
            return result["result"]

async def deploy_branding():
    # Load environment variables
    load_dotenv()
    
    # Process image
    processor = WallyImageProcessor('wally_original.jpg')
    image_hashes = processor.prepare_all_formats()
    metadata = processor.generate_metadata(image_hashes)
    
    # Initialize Solana connection
    rpc_url = os.getenv('SOLANA_RPC_URL')
    private_key = bytes.fromhex(os.getenv('PRIVATE_KEY'))
    program_id = Pubkey.from_string(os.getenv('PROGRAM_ID'))
    
    # Create keypair from private key
    keypair = Keypair.from_bytes(private_key)
    
    try:
        async with SolanaClient(rpc_url) as client:
            # Prepare branding metadata for contract
            branding_data = {
                'name': metadata['name'],
                'symbol': metadata['symbol'],
                'description': metadata['description'],
                'logo_uri': metadata['images']['token'],
                'images': {
                    'token': metadata['images']['token'],
                    'twitter': metadata['images']['twitter'],
                    'telegram': metadata['images']['telegram'],
                    'discord': metadata['images']['discord'],
                    'favicon': metadata['images']['favicon'],
                    'high_res': metadata['images']['high_res'],
                },
                'colors': metadata['colors'],
                'official_links': metadata['official_links']
            }
            
            # Get the latest blockhash
            latest_blockhash = await client.get_latest_blockhash()
            
            # Create update branding instruction
            instruction_data = encode_branding_data(branding_data)
            update_branding_ix = Instruction(
                program_id=program_id,
                accounts=[
                    {"pubkey": Pubkey.from_string(os.getenv('TOKEN_STATE_ADDRESS')), "is_signer": False, "is_writable": True},
                    {"pubkey": keypair.pubkey(), "is_signer": True, "is_writable": False},
                    {"pubkey": SYS_PROGRAM_ID, "is_signer": False, "is_writable": False}
                ],
                data=instruction_data
            )
            
            # Create and sign transaction
            transaction = Transaction()
            transaction.recent_blockhash = latest_blockhash
            transaction.add(update_branding_ix)
            transaction.sign(keypair)
            
            # Send transaction
            signature = await client.send_transaction(bytes(transaction))
            
            print("Branding updated successfully!")
            print(f"Transaction signature: {signature}")
            print(f"Token image hash: {metadata['images']['token']}")
            
    except Exception as e:
        print(f"Error updating branding: {e}")

if __name__ == "__main__":
    asyncio.run(deploy_branding()) 