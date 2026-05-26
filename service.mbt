///|
pub(all) struct RawResponse {
  data : String
  status_code : Int
  content_type : String
}

///|
fn raw_ok_json(data : String) -> RawResponse {
  { data, status_code: 200, content_type: "application/json" }
}

///|
fn raw_ok_html(data : String) -> RawResponse {
  { data, status_code: 200, content_type: "text/html; charset=utf-8" }
}

///|
fn raw_bad_request(msg : String) -> RawResponse {
  { data: msg, status_code: 400, content_type: "text/plain; charset=utf-8" }
}

///|
fn raw_server_error(msg : String, status_code : Int) -> RawResponse {
  { data: msg, status_code, content_type: "text/plain; charset=utf-8" }
}

///|
pub(all) enum HttpErrorCode {
  BadRequest
  Unauthorized
  Forbidden
  NotFound
  Conflict
  UnprocessableContent
  TooManyRequests
  InternalServerError
  BadGateway
  ServiceUnavailable
} derive(Eq, Hash, Debug)

///|
pub fn HttpErrorCode::as_int(self : HttpErrorCode) -> Int {
  match self {
    BadRequest => 400
    Unauthorized => 401
    Forbidden => 403
    NotFound => 404
    Conflict => 409
    UnprocessableContent => 422
    TooManyRequests => 429
    InternalServerError => 500
    BadGateway => 502
    ServiceUnavailable => 503
  }
}

///|
pub(all) struct ServiceError {
  status_code : HttpErrorCode
  message : String
}

///|
pub fn ServiceError::new(
  status_code : HttpErrorCode,
  message : String,
) -> ServiceError {
  { status_code, message }
}

///|
pub(all) struct MethodErrorInfo[Meta] {
  error_message : String
  method_name : String
  raw_request : String
  request_meta : Meta
}

///|
enum MethodInvocationError {
  Service(ServiceError)
  Unknown(String)
}

///|
struct MethodEntry[Meta] {
  name : String
  number : Int
  doc : String
  request_type_descriptor_json : Json
  response_type_descriptor_json : Json
  invoke : (String, Bool, Bool, Meta) -> Result[String, MethodInvocationError]
}

///|
pub struct Service[Meta] {
  keep_unrecognized_values : Bool
  can_send_unknown_error_message : (MethodErrorInfo[Meta]) -> Bool
  error_logger : (MethodErrorInfo[Meta]) -> Unit
  studio_app_js_url : String
  by_num : @hashmap.HashMap[Int, MethodEntry[Meta]]
  by_name : @hashmap.HashMap[String, Int]
}

///|
pub fn[Meta] Service::handle_request(
  self : Service[Meta],
  body : String,
  meta : Meta,
) -> RawResponse {
  match body {
    "" | "studio" => return serve_studio(self.studio_app_js_url)
    "list" => return self.serve_list()
    _ => ()
  }

  if body.has_prefix("{") ||
    body.has_prefix(" ") ||
    body.has_prefix("\n") ||
    body.has_prefix("\t") {
    self.handle_json_request(body, meta)
  } else {
    self.handle_colon_request(body, meta)
  }
}

///|
fn[Meta] Service::serve_list(self : Service[Meta]) -> RawResponse {
  let methods : Array[Json] = []
  for _, entry in self.by_num {
    let fields : Array[(String, Json)] = [
      ("method", entry.name.to_json()),
      ("number", entry.number.to_json()),
      ("request", entry.request_type_descriptor_json),
      ("response", entry.response_type_descriptor_json),
    ]
    if entry.doc != "" {
      fields.push(("doc", entry.doc.to_json()))
    }
    methods.push(Json::object(Map(fields)))
  }
  raw_ok_json(
    Json::object(Map([("methods", methods.to_json())])).stringify(indent=2),
  )
}

///|
fn[Meta] Service::handle_json_request(
  self : Service[Meta],
  body : String,
  meta : Meta,
) -> RawResponse {
  let root = @json.parse(body) catch {
    _ => return raw_bad_request("bad request: invalid JSON")
  }

  let obj = match root {
    Json::Object(v) => v
    _ => return raw_bad_request("bad request: expected JSON object")
  }

  let entry = match obj.get("method") {
    Some(Json::Number(n, ..)) => {
      let number = n.to_int()
      match self.by_num.get(number) {
        Some(e) => e
        None =>
          return raw_bad_request(
            "bad request: method not found: " + number.to_string(),
          )
      }
    }
    Some(Json::String(name)) =>
      match self.by_name.get(name) {
        Some(number) =>
          match self.by_num.get(number) {
            Some(e) => e
            None =>
              return raw_bad_request("bad request: method index out of sync")
          }
        None => return raw_bad_request("bad request: method not found: " + name)
      }
    Some(_) =>
      return raw_bad_request(
        "bad request: 'method' field must be a string or integer",
      )
    None =>
      return raw_bad_request("bad request: missing 'method' field in JSON")
  }

  let request_val = match obj.get("request") {
    Some(v) => v
    None =>
      return raw_bad_request("bad request: missing 'request' field in JSON")
  }

  self.invoke_entry(
    entry,
    request_val.stringify(),
    self.keep_unrecognized_values,
    true,
    meta,
  )
}

///|
fn[Meta] Service::handle_colon_request(
  self : Service[Meta],
  body : String,
  meta : Meta,
) -> RawResponse {
  let chunks = body.split(":").collect()
  if chunks.length() < 4 {
    return raw_bad_request("bad request: invalid request format")
  }

  let name_str = chunks[0].to_owned()
  let number_str = chunks[1].to_owned()
  let format = chunks[2].to_owned()

  let request_builder = StringBuilder::new()
  for i in 3..<chunks.length() {
    if i > 3 {
      request_builder.write_char(':')
    }
    request_builder.write_string(chunks[i].to_owned())
  }
  let request_json = if request_builder.is_empty() {
    "{}"
  } else {
    request_builder.to_string()
  }

  let entry = if number_str == "" {
    match self.by_name.get(name_str) {
      Some(number) =>
        match self.by_num.get(number) {
          Some(e) => e
          None =>
            return raw_bad_request("bad request: method index out of sync")
        }
      None =>
        return raw_bad_request("bad request: method not found: " + name_str)
    }
  } else {
    let number = @string.parse_int(number_str) catch {
      _ => return raw_bad_request("bad request: can't parse method number")
    }
    match self.by_num.get(number) {
      Some(e) => e
      None =>
        return raw_bad_request(
          "bad request: method not found: " +
          name_str +
          "; number: " +
          number.to_string(),
        )
    }
  }

  let readable = format == "readable"
  self.invoke_entry(
    entry,
    request_json,
    self.keep_unrecognized_values,
    readable,
    meta,
  )
}

///|
fn[Meta] Service::invoke_entry(
  self : Service[Meta],
  entry : MethodEntry[Meta],
  request_json : String,
  keep_unrecognized : Bool,
  readable : Bool,
  meta : Meta,
) -> RawResponse {
  let raw_request = request_json
  match (entry.invoke)(request_json, keep_unrecognized, readable, meta) {
    Ok(response_json) => raw_ok_json(response_json)
    Err(err) =>
      match err {
        Service(service_error) => {
          let status_code = service_error.status_code.as_int()
          let msg = if service_error.message == "" {
            http_status_text(status_code)
          } else {
            service_error.message
          }
          let info : MethodErrorInfo[Meta] = {
            error_message: msg,
            method_name: entry.name,
            raw_request,
            request_meta: meta,
          }
          (self.error_logger)(info)
          raw_server_error(msg, status_code)
        }
        Unknown(message) => {
          let info : MethodErrorInfo[Meta] = {
            error_message: message,
            method_name: entry.name,
            raw_request,
            request_meta: meta,
          }
          let can_send = (self.can_send_unknown_error_message)(info)
          (self.error_logger)(info)
          let msg = if can_send {
            "server error: " + message
          } else {
            "server error"
          }
          raw_server_error(msg, 500)
        }
      }
  }
}

///|
pub struct ServiceBuilder[Meta] {
  keep_unrecognized_values : Bool
  can_send_unknown_error_message : (MethodErrorInfo[Meta]) -> Bool
  error_logger : (MethodErrorInfo[Meta]) -> Unit
  studio_app_js_url : String
  by_num : @hashmap.HashMap[Int, MethodEntry[Meta]]
  by_name : @hashmap.HashMap[String, Int]
}

///|
pub fn[Meta] ServiceBuilder::new() -> ServiceBuilder[Meta] {
  {
    keep_unrecognized_values: false,
    can_send_unknown_error_message: _ => false,
    error_logger: info => {
      println(
        "skir: error in method \"" +
        info.method_name +
        "\": " +
        info.error_message,
      )
    },
    studio_app_js_url: DEFAULT_STUDIO_APP_JS_URL,
    by_num: @hashmap.HashMap([], capacity=16),
    by_name: @hashmap.HashMap([], capacity=16),
  }
}

///|
pub fn[Req, Resp, Meta] ServiceBuilder::add_method(
  self : ServiceBuilder[Meta],
  rpc_method : @client.Method[Req, Resp],
  impl_fn : (Req, Meta) -> Result[Resp, ServiceError],
) -> Result[ServiceBuilder[Meta], String] {
  if self.by_num.contains(rpc_method.number) {
    return Err(
      "skir: method number " +
      rpc_method.number.to_string() +
      " already registered",
    )
  }

  let req_serializer = rpc_method.request_serializer
  let resp_serializer = rpc_method.response_serializer
  let entry : MethodEntry[Meta] = {
    name: rpc_method.name,
    number: rpc_method.number,
    doc: rpc_method.doc,
    request_type_descriptor_json: rpc_method.request_serializer
    .type_descriptor()
    .as_json(),
    response_type_descriptor_json: rpc_method.response_serializer
    .type_descriptor()
    .as_json(),
    invoke: (request_json, keep_unrecognized, readable, meta) => {
      let policy = if keep_unrecognized {
        @client.UnrecognizedValues::Keep
      } else {
        @client.UnrecognizedValues::Drop
      }

      let req = match
        req_serializer.from_json_code(request_json, unrecognized_values=policy) {
        Ok(v) => v
        Err(e) =>
          return Err(
            Service(
              ServiceError::new(
                HttpErrorCode::BadRequest,
                "bad request: can't parse JSON: " + e,
              ),
            ),
          )
      }

      match impl_fn(req, meta) {
        Ok(resp) => {
          let response_json = if readable {
            resp_serializer.to_readable_json(resp).stringify()
          } else {
            resp_serializer.to_dense_json_code(resp)
          }
          Ok(response_json)
        }
        Err(service_err) => Err(Service(service_err))
      }
    },
  }

  let next = self
  next.by_name.set(rpc_method.name, rpc_method.number)
  next.by_num.set(rpc_method.number, entry)
  Ok(next)
}

///|
pub fn[Meta] ServiceBuilder::set_keep_unrecognized_values(
  self : ServiceBuilder[Meta],
  keep : Bool,
) -> ServiceBuilder[Meta] {
  { ..self, keep_unrecognized_values: keep }
}

///|
pub fn[Meta] ServiceBuilder::set_can_send_unknown_error_message(
  self : ServiceBuilder[Meta],
  can : Bool,
) -> ServiceBuilder[Meta] {
  { ..self, can_send_unknown_error_message: _ => can }
}

///|
pub fn[Meta] ServiceBuilder::set_can_send_unknown_error_message_fn(
  self : ServiceBuilder[Meta],
  f : (MethodErrorInfo[Meta]) -> Bool,
) -> ServiceBuilder[Meta] {
  { ..self, can_send_unknown_error_message: f }
}

///|
pub fn[Meta] ServiceBuilder::set_error_logger(
  self : ServiceBuilder[Meta],
  logger : (MethodErrorInfo[Meta]) -> Unit,
) -> ServiceBuilder[Meta] {
  { ..self, error_logger: logger }
}

///|
pub fn[Meta] ServiceBuilder::set_studio_app_js_url(
  self : ServiceBuilder[Meta],
  url : String,
) -> ServiceBuilder[Meta] {
  { ..self, studio_app_js_url: url }
}

///|
pub fn[Meta] ServiceBuilder::build(
  self : ServiceBuilder[Meta],
) -> Service[Meta] {
  {
    keep_unrecognized_values: self.keep_unrecognized_values,
    can_send_unknown_error_message: self.can_send_unknown_error_message,
    error_logger: self.error_logger,
    studio_app_js_url: self.studio_app_js_url,
    by_num: self.by_num,
    by_name: self.by_name,
  }
}

///|
fn serve_studio(js_url : String) -> RawResponse {
  raw_ok_html(studio_html(js_url))
}

///|
fn studio_html(js_url : String) -> String {
  let safe = html_escape_attr(js_url)
  "<!DOCTYPE html><html><head><meta charset=\"utf-8\" />" +
  "<title>RPC Studio</title>" +
  "<script src=\"" +
  safe +
  "\"></script></head><body style=\"margin: 0; padding: 0;\">" +
  "<skir-studio-app></skir-studio-app></body></html>"
}

///|
fn html_escape_attr(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="\"", new="&#34;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
}

///|
fn http_status_text(code : Int) -> String {
  match code {
    200 => "OK"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    409 => "Conflict"
    422 => "Unprocessable Entity"
    429 => "Too Many Requests"
    500 => "Internal Server Error"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    _ => "Error"
  }
}

///|
const DEFAULT_STUDIO_APP_JS_URL : String = "https://cdn.jsdelivr.net/npm/skir-studio/dist/skir-studio-standalone.js"
