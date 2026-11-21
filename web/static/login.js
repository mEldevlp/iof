"use strict";

const form = $("#login-form");
const error = $("#login-error");
$("#password-changed").hidden = new URLSearchParams(location.search).get("password") !== "changed";

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button");
  button.disabled = true;
  error.hidden = true;
  try {
    await postJson("api/login", { login: $("#login").value, password: $("#password").value });
    location.replace("./");
  } catch (e) {
    error.textContent = e instanceof TypeError ? "Не удалось связаться с панелью." : e.message;
    error.hidden = false;
    $("#password").select();
  } finally {
    button.disabled = false;
  }
});
