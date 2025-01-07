using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using UserApi.Data;

namespace UserApi.Controllers;

[ApiController]
[Route("api")]
public class ApiController : ControllerBase
{
    private readonly AppDbContext _context;

    public ApiController(AppDbContext context)
    {
        _context = context;
    }

    [HttpGet]
    [Route("health")]
    public IActionResult Get()
    {
        return Ok(new
        {
            status = "healthy",
            message = "Application is running"
        });
    }

    [HttpGet]
    [Route("users")]
    public async Task<IActionResult> GetUsers([FromServices] AppDbContext context)
    {
        var users = await _context.Users.ToListAsync();
        return Ok(users);
    }

    [HttpGet("users/{id:int}")]
    public async Task<IActionResult> GetUserById(int id)
    {
        var user = await _context.Users.FindAsync(id);

        if (user == null)
        {
            return NotFound(new
            {
                status = "error",
                message = $"User with ID {id} not found"
            });
        }

        return Ok(user);
    }
}