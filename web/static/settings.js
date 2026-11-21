"use strict";

const form = $("#password-form");
const error = $("#password-error");

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button");
  const current = $("#current-password").value;
  const password = $("#new-password").value;
  const confirmation = $("#confirm-password").value;
  button.disabled = true;
  error.hidden = true;
  try {
    if (password !== confirmation) throw new Error("Пароли не совпадают.");
    if (DEMO) throw new Error("Смена пароля доступна на рабочей панели.");
    await postJson("api/password", { current, password, confirmation });
    form.reset();
    location.replace("login.html?password=changed");
  } catch (e) {
    error.textContent = e instanceof TypeError ? "Не удалось связаться с панелью." : e.message;
    error.hidden = false;
  } finally {
    button.disabled = false;
  }
});
