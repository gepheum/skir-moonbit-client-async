///|
/// Starts the async RPC service used by the e2e scripts.
async fn main {
  let users = @hashmap.HashMap([], capacity=8)

  let builder = match
    @client_async.ServiceBuilder::new().add_method(
      @skirout_service_skir.get_user_method,
      (req, _meta) => {
        let user = users.get(req.user_id)
        Ok(@skirout_service_skir.GetUserResponse::new(user~))
      },
    ) {
    Ok(builder) => builder
    Err(_) => panic()
  }

  let service = match
    builder.add_method(@skirout_service_skir.add_user_method, (req, _meta) => {
      if req.user.user_id == 0 {
        Err(
          @client_async.ServiceError::new(
            "user_id must be non-zero",
            status_code=Some(@client_async.HttpErrorCode::Code_400_BadRequest),
          ),
        )
      } else {
        users.set(req.user.user_id, req.user)
        Ok(@skirout_service_skir.AddUserResponse::new())
      }
    }) {
    Ok(builder) => builder.build()
    Err(_) => panic()
  }

  let server = @http.Server(@socket.Addr::parse("0.0.0.0:8787"))
  println("Listening on http://localhost:8787/myapi")
  server.run_forever() <| ((request, body, conn) => {
    let body_text = match request.meth {
      Get => extract_query_body(request.path)
      _ => body.read_all().text()
    }
    let response = service.handle_request(body_text, ())
    conn.send_response(response.status_code, "OK", extra_headers={
      "Content-Type": response.content_type,
    })
    conn.write_string(response.data)
  })
}

///|
fn extract_query_body(path : String) -> String {
  let i = match path.find("?") {
    Some(v) => v
    None => return ""
  }
  let raw = path[i + 1:]
  percent_decode(raw)
}

///|
fn percent_decode(input : StringView) -> String {
  let bytes = @utf8.encode(input.to_owned())
  let out : Array[Byte] = []
  let mut i = 0
  while i < bytes.length() {
    let c = bytes[i]
    if c == b'+' {
      out.push(b' ')
      i = i + 1
    } else if c == b'%' && i + 2 < bytes.length() {
      match (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
        (Some(hi), Some(lo)) => {
          out.push((hi * 16 + lo).to_byte())
          i = i + 3
        }
        _ => {
          out.push(c)
          i = i + 1
        }
      }
    } else {
      out.push(c)
      i = i + 1
    }
  }
  @utf8.decode(Bytes::from_array(out)[:]) catch {
    _ => input.to_owned()
  }
}

///|
fn hex_value(b : Byte) -> Int? {
  if b >= b'0' && b <= b'9' {
    Some((b - b'0').to_int())
  } else if b >= b'a' && b <= b'f' {
    Some(10 + (b - b'a').to_int())
  } else if b >= b'A' && b <= b'F' {
    Some(10 + (b - b'A').to_int())
  } else {
    None
  }
}
