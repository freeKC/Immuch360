# Immich responses for the unit tests

Written by hand from the response schemas of the Immich server of this repository (`server/src/dtos/time-bucket.dto.ts`,
`asset-response.dto.ts`, `exif.dto.ts`, `server.dto.ts` at commit a0af38a54, server 3.3), with the values a server
returns for a library holding one 360° photo of an Insta360 X4, one flat photo and one video. Not captured from a live
server: replace them with captures (`curl -H "x-api-key: ..." https://<server>/api/...`) when one is at hand.
